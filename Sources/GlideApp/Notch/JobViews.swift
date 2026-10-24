import SwiftUI
import AppKit
import AgentKit
import AutomationKit

// Background jobs in the notch: the progress ring in the wing, the running-job pill, the
// "Background jobs" list in the detail view, and the confirmation / finished card.

// MARK: - Data source

/// What the job UI needs from `JobCenter`. The views talk to this instead of `JobCenter`
/// directly so the snapshot renderer can show realistic jobs without a database or a model
/// (`JobCenter.jobs` is read-only from outside AgentKit). Conformers must be `@Observable` so
/// the views refresh as jobs progress.
@MainActor
protocol JobsSource: AnyObject {
    var jobs: [JobRecord] { get }
    var pendingApprovals: [String: ApprovalRequest] { get }
    var activeJob: JobRecord? { get }
    func job(_ id: String) -> JobRecord?
    func items(_ jobID: String, limit: Int) -> [JobItem]
    func events(_ jobID: String, limit: Int) -> [ActivityEntry]
    /// The job's `report.md`, if it has been written.
    func report(_ jobID: String) -> String?
    func start(_ id: String)
    func pause(_ id: String)
    func resume(_ id: String)
    func stop(_ id: String)
    func retryFailedItems(_ id: String)
    func delete(_ id: String)
    func respond(jobID: String, decision: ApprovalDecision)
    func exportResults(_ jobID: String, to url: URL) throws
}

extension JobCenter: JobsSource {
    func report(_ jobID: String) -> String? {
        guard let job = job(jobID) else { return nil }
        return JobReport.read(folder: job.folder)
    }
}

enum JobReport {
    /// Reports are previews: anything past this is cut (the full file opens in an editor).
    static let maxBytes = 256 * 1024

    static func url(folder: String) -> URL {
        URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent("report.md")
    }

    /// Reads at most `maxBytes` of `report.md`, so a runaway report can't stall the UI.
    static func read(folder: String) -> String? {
        guard !folder.isEmpty, let handle = try? FileHandle(forReadingFrom: url(folder: folder)) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes), !data.isEmpty else { return nil }
        // A cut in the middle of a multi-byte character would fail strict decoding.
        let text = String(decoding: data, as: UTF8.self)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}

extension JobsSource {
    /// Jobs that aren't finished ("Background jobs"): running ones first, then the most
    /// recently updated.
    var unfinishedJobs: [JobRecord] {
        jobs.filter { !$0.status.isFinished }.sorted {
            $0.status.isActive != $1.status.isActive ? $0.status.isActive : $0.updatedAt > $1.updatedAt
        }
    }
}

// MARK: - Presentation helpers

extension JobStatus {
    var title: String {
        switch self {
        case .planning: return "Planning"
        case .awaitingConfirmation: return "Ready to start"
        case .running: return "Running"
        case .paused: return "Paused"
        case .waiting: return "Waiting"
        case .needsInput: return "Needs you"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        }
    }

    var tone: BK.Tone {
        switch self {
        case .planning, .running: return .info
        case .awaitingConfirmation, .needsInput, .paused: return .warning
        case .waiting, .stopped: return .neutral
        case .completed: return .success
        case .failed: return .danger
        }
    }

    /// The job can be paused right now. Only a running job: a planning job has no runner yet,
    /// so `JobCenter.pause` has nothing to pause.
    var canPause: Bool { self == .running }
}

extension JobRecord {
    /// One line for lists and pills: the engine's status line, or something sensible when
    /// it hasn't written one yet.
    var displayLine: String {
        let line = statusLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if !line.isEmpty { return line }
        if status == .waiting, let wake = nextWakeAt { return "Continues \(JobFormat.when(wake))" }
        if status == .awaitingConfirmation { return "Waiting for you to start it" }
        if usage.itemsTotal > 0 {
            var s = "\(usage.itemsDone)/\(usage.itemsTotal) items"
            if usage.itemsFailed > 0 { s += " · \(usage.itemsFailed) failed" }
            return s
        }
        if let err = lastError, !err.isEmpty, status == .failed || status == .needsInput { return err }
        return status.title
    }

    /// The job has failed items that "Retry failed" can re-queue.
    var canRetryFailed: Bool {
        usage.itemsFailed > 0 && (status.isFinished || status == .paused || status == .needsInput)
    }

    /// Waiting for a free slot (Settings › Jobs limits how many run at once), not for a time.
    /// JobCenter starts it by itself when another job finishes.
    var isQueued: Bool { status == .waiting && nextWakeAt == nil }

    /// "Resume" / "Run now" does something. A queued job can't jump the queue (`JobCenter.resume`
    /// ignores it), so it offers neither.
    var canResume: Bool { status.isResumable && !isQueued }
}

enum JobFormat {
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0 s" }
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        let h = s / 3600, m = (s % 3600) / 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    static func minutes(_ minutes: Double) -> String { duration(minutes * 60) }

    static func cost(_ usd: Double?, known: Bool = true) -> String {
        guard known, let usd, usd.isFinite else { return "Unknown" }
        if usd > 0 && usd < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", usd)
    }

    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 10_000 { return "\(n / 1000)k" }
        if n >= 1000 { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }

    static func relative(_ date: Date, to now: Date = Date()) -> String {
        if abs(date.timeIntervalSince(now)) < 30 { return "just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: now)
    }

    /// "today at 09:00", "tomorrow at 09:00", or a short date.
    static func when(_ date: Date) -> String {
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(date) { return "today at \(time)" }
        if cal.isDateInTomorrow(date) { return "tomorrow at \(time)" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Compact estimate line for cards and notifications.
    static func estimate(_ e: JobEstimate) -> String {
        var parts: [String] = []
        if e.items > 0 { parts.append("\(e.items) items") }
        parts.append("about \(minutes(max(1, e.minutes)))")
        parts.append(e.costUSD.map { "~\(cost($0))" } ?? "cost unknown")
        return parts.joined(separator: " · ")
    }
}

// MARK: - Progress ring

/// Determinate progress ring for a job (falls back to BoardKit's spinner when the job has
/// no item count yet). Static when idle so it costs nothing while it sits in the menu bar.
struct BKJobRing: View {
    var fraction: Double?
    var size: CGFloat = 14
    var lineWidth: CGFloat = 2
    var trackColor: Color = BK.Palette.n700
    /// Paused, waiting or needing input: drawn in the warning color instead of the accent.
    var dimmed = false

    var body: some View {
        if let fraction {
            let value = min(1, max(0, fraction.isFinite ? fraction : 0))
            ZStack {
                Circle().stroke(trackColor, lineWidth: lineWidth)
                Circle().trim(from: 0, to: max(0.015, value))
                    .stroke(dimmed ? AnyShapeStyle(BK.Tone.warning.color)
                                   : AnyShapeStyle(AngularGradient(colors: [BK.Palette.accent500, BK.Palette.accent400], center: .center)),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.35), value: value)
            }
            .frame(width: size, height: size)
            .accessibilityElement()
            .accessibilityLabel("Job progress")
            .accessibilityValue("\(Int((value * 100).rounded())) percent")
        } else if dimmed {
            Circle().stroke(BK.Tone.warning.color.opacity(0.8), style: StrokeStyle(lineWidth: lineWidth, dash: [2, 2.5]))
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            BKProgressRing(size: size, lineWidth: lineWidth, trackColor: trackColor)
        }
    }
}

/// Ring (plus a count when there's room) shown in the notch's right wing while a job runs.
struct NotchJobWing: View {
    let job: JobRecord
    var showCount: Bool

    var body: some View {
        HStack(spacing: 5) {
            if showCount, job.usage.itemsTotal > 0 {
                Text("\(job.usage.itemsDone + job.usage.itemsFailed + job.usage.itemsSkipped)/\(job.usage.itemsTotal)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(BK.Notch.secondary)
                    .contentTransition(.numericText())
            }
            BKJobRing(fraction: job.progressFraction, size: 14, lineWidth: 2, trackColor: BK.Palette.n800, dimmed: !job.status.isActive)
        }
        .help(job.displayLine)
    }
}

// MARK: - Running pill

/// Compact row for one background job: ring, title, status line and controls. Used for the
/// running-job pill above the task field and in the "Background jobs" list.
struct NotchJobRow: View {
    @Bindable var model: NotchModel
    let job: JobRecord
    /// The pill variant has the field background and the iridescent rim while running.
    var pill = false

    var body: some View {
        HStack(spacing: 10) {
            BKJobRing(fraction: job.progressFraction, size: pill ? 20 : 16, lineWidth: pill ? 2.4 : 2, trackColor: BK.Palette.n800,
                      dimmed: !job.status.isActive)
            VStack(alignment: .leading, spacing: 1) {
                Text(job.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(BK.Notch.text).lineLimit(1)
                Text(job.displayLine).font(.system(size: 11.5)).foregroundStyle(BK.Notch.secondary).lineLimit(1)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: job.displayLine)
            }
            Spacer(minLength: 6)
            if !pill { BKBadge(text: job.status.title, tone: job.status.tone) }
            controls
        }
        .padding(.leading, pill ? 12 : 8).padding(.trailing, 6).padding(.vertical, pill ? 6 : 5)
        .background {
            if pill {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(BK.Notch.field)
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04))
            }
        }
        .overlay {
            if pill { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(BK.Notch.border) }
        }
        .bkIridescentRim(pill && job.status == .running, cornerRadius: 14)
    }

    @ViewBuilder var controls: some View {
        let jobs = model.jobs
        if job.status == .awaitingConfirmation {
            BKIconButton(systemName: "play.fill", help: "Start job") { jobs.start(job.id) }
        } else if job.status.canPause {
            BKIconButton(systemName: "pause.fill", help: "Pause job") { jobs.pause(job.id) }
        } else if job.canResume {
            BKIconButton(systemName: "play.fill", help: job.status == .waiting ? "Run now" : "Resume job") { jobs.resume(job.id) }
        }
        if !job.status.isFinished {
            BKIconButton(systemName: "stop.fill", help: "Stop job", tone: .danger) { model.stopJob(job.id) }
        }
        if pill {
            BKIconButton(systemName: "chevron.down", help: "Show background jobs") { model.showJobsDetail() }
        } else {
            BKIconButton(systemName: "arrow.up.right", help: "Open in Settings") { model.openJob(job.id) }
        }
    }
}

// MARK: - Background jobs list (detail view)

struct NotchJobsSection: View {
    @Bindable var model: NotchModel
    /// Under a quick task's timeline: a header and at most two rows.
    var compact: Bool

    var body: some View {
        let list = model.jobs.unfinishedJobs
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                // The full list sits under a "Background jobs" title already.
                Text(compact ? "Background jobs" : (list.isEmpty ? "Nothing running" : "\(list.count) not finished"))
                    .font(.system(size: compact ? 11.5 : 12, weight: .semibold)).foregroundStyle(BK.Notch.secondary)
                Spacer()
                Button("All jobs") { model.openSettings("jobs") }
                    .buttonStyle(BKButtonStyle(kind: .ghost, compact: true, onDark: true))
            }
            if list.isEmpty {
                Text("No background jobs right now. Long or repetitive requests run here without taking over your screen.")
                    .font(.system(size: 12)).foregroundStyle(BK.Notch.tertiary).fixedSize(horizontal: false, vertical: true)
            } else if compact {
                ForEach(list.prefix(2)) { NotchJobRow(model: model, job: $0) }
                if list.count > 2 {
                    Text("+\(list.count - 2) more").font(.system(size: 11)).foregroundStyle(BK.Notch.tertiary).padding(.leading, 8)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(list) { NotchJobRow(model: model, job: $0) }
                    }
                }
            }
        }
    }
}

// MARK: - Confirmation / finished card

/// The job that needs the user: a confirmation card (estimate, Start / Cancel) for jobs
/// awaiting confirmation, otherwise a result card (finished, failed, needs input).
struct NotchJobCard: View {
    @Bindable var model: NotchModel

    var body: some View {
        if let job = model.attentionJob {
            Group {
                if job.status == .awaitingConfirmation { confirmation(job) } else { result(job) }
            }
            // Another job's card (or this job in a new state) gets new buttons: a press that
            // began on the previous card is dropped instead of finishing on this one.
            .id("\(job.id)/\(job.status.rawValue)")
        }
    }

    func confirmation(_ job: JobRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                let chip = BK.Tone.info.chip(dark: true)
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(chip.text)
                    .frame(width: 26, height: 26).background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(chip.background))
                Text("Start this background job?").font(.system(size: 13, weight: .semibold)).foregroundStyle(BK.Notch.text)
                Spacer()
                BKIconButton(systemName: "chevron.up", help: "Decide later") { model.dismissJobCard() }
            }
            Text(job.title).font(.system(size: 14, weight: .medium)).foregroundStyle(BK.Notch.text).lineLimit(2)
            if let e = job.plan?.estimate {
                HStack(spacing: 6) {
                    if e.items > 0 { BKBadge(text: "\(e.items) items", tone: .info, icon: "list.bullet") }
                    BKBadge(text: "~\(JobFormat.minutes(max(1, e.minutes)))", tone: .info, icon: "clock")
                    BKBadge(text: e.costUSD.map { "~\(JobFormat.cost($0))" } ?? "Cost unknown", tone: e.costUSD == nil ? .neutral : .info)
                    if e.modelCalls > 0 { BKBadge(text: "\(e.modelCalls) model calls") }
                }
                if !e.notes.isEmpty {
                    Text(e.notes).font(.system(size: 11.5)).foregroundStyle(BK.Notch.secondary).lineLimit(1)
                }
            } else {
                Text(job.displayLine).font(.system(size: 11.5)).foregroundStyle(BK.Notch.secondary).lineLimit(2)
            }
            HStack {
                Button("Review in Settings") { model.openJob(job.id) }.buttonStyle(BKButtonStyle(kind: .ghost, compact: true, onDark: true))
                Spacer()
                // Starting a job is the user's consent to its estimate: never the agent's click.
                Button("Cancel") { model.userDecision { model.cancelJob(job.id) } }.buttonStyle(BKButtonStyle(kind: .secondary, onDark: true))
                Button("Start") { model.userDecision { model.startJob(job.id) } }.buttonStyle(BKButtonStyle(kind: .primary))
            }
        }
        .padding(.top, 8)
    }

    func result(_ job: JobRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                BKAgentOrb(mode: orb(job), size: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(heading(job)) · \(job.title)").font(.system(size: 13, weight: .semibold)).foregroundStyle(BK.Notch.text).lineLimit(1)
                    Text(message(job)).font(.system(size: 12)).foregroundStyle(BK.Notch.secondary).lineLimit(3).textSelection(.enabled)
                }
                Spacer()
            }
            HStack {
                Button(job.status == .completed ? "View report" : "View job") { model.openJob(job.id) }
                    .buttonStyle(BKButtonStyle(kind: .ghost, compact: true, onDark: true))
                Spacer()
                if job.canRetryFailed {
                    Button("Retry failed") { model.userDecision { model.dismissJobCard(); model.jobs.retryFailedItems(job.id) } }
                        .buttonStyle(BKButtonStyle(kind: .secondary, compact: true, onDark: true))
                }
                if job.status.isResumable && job.status != .waiting {
                    // Resuming can also extend a budget the job ran out of.
                    Button("Resume") { model.userDecision { model.dismissJobCard(); model.jobs.resume(job.id) } }
                        .buttonStyle(BKButtonStyle(kind: .secondary, compact: true, onDark: true))
                }
                Button("Close") { model.dismissJobCard() }.buttonStyle(BKButtonStyle(kind: .secondary, compact: true, onDark: true))
            }
        }
        .padding(.top, 8)
    }

    func orb(_ job: JobRecord) -> BKAgentOrb.Mode {
        switch job.status {
        case .completed: return .success
        case .stopped, .paused, .needsInput: return .paused
        default: return .error
        }
    }

    func heading(_ job: JobRecord) -> String {
        switch job.status {
        case .completed: return "Job finished"
        case .stopped: return "Job stopped"
        case .needsInput: return "Job needs you"
        case .paused: return "Job paused"
        default: return "Job failed"
        }
    }

    func message(_ job: JobRecord) -> String {
        if job.status == .completed, let s = job.summary, !s.isEmpty { return s }
        if let e = job.lastError, !e.isEmpty, job.status != .completed { return e }
        return job.displayLine
    }
}
