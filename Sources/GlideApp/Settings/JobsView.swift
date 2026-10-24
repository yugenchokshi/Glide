import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AgentKit
import AutomationKit

/// Settings › Jobs: every background job (list → detail) and the defaults new jobs start with.
struct JobsSettingsView: View {
    @Bindable var store: SettingsStore
    @Bindable var nav: SettingsNavigation
    let jobs: any JobsSource

    var body: some View {
        if let id = nav.selectedJobID, let job = jobs.job(id) {
            JobDetailView(job: job, jobs: jobs) { nav.selectedJobID = nil }
                .id(job.id)
        } else {
            BKSectionHeader(title: "Jobs",
                            subtitle: "Long tasks run as background jobs: loops over many items, waits and schedules. Progress is saved after every item, so a job survives quitting Glide or restarting your Mac.")
            JobsListSection(jobs: jobs) { nav.selectedJobID = $0 }
                .onAppear { jobs.reload() }
            JobDefaultsSection(store: store)
        }
    }
}

// MARK: - List

private struct JobsListSection: View {
    let jobs: any JobsSource
    var onSelect: (String) -> Void

    var body: some View {
        let list = jobs.jobs
        BKGroupHeader(title: list.isEmpty ? "All jobs" : "\(list.count) job\(list.count == 1 ? "" : "s")")
        if list.isEmpty {
            BKEmptyState(icon: "square.stack.3d.up", title: "No jobs yet",
                         message: "Ask for something long or repetitive — “for each row in leads.xlsx, find the company's website” — and Glide runs it here in the background.")
        } else {
            BKGroup {
                ForEach(list) { job in
                    JobListRow(job: job) { onSelect(job.id) }
                }
            }
        }
    }
}

private struct JobListRow: View {
    let job: JobRecord
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        BKThemeReader { t in
            Button(action: action) {
                HStack(spacing: 11) {
                    ZStack {
                        BKJobRing(fraction: job.progressFraction ?? (job.status == .completed ? 1 : nil), size: 26, lineWidth: 3,
                                  trackColor: t.dark ? BK.Palette.n800 : BK.Palette.n200, dimmed: !job.status.isActive && job.status != .completed)
                        if job.status.isFinished {
                            Image(systemName: job.status == .completed ? "checkmark" : (job.status == .failed ? "exclamationmark" : "stop.fill"))
                                .font(.system(size: 9, weight: .bold)).foregroundStyle(job.status.tone.color)
                        }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(job.title).font(BK.Font.bodyMedium).foregroundStyle(t.text).lineLimit(1)
                        HStack(spacing: 6) {
                            BKBadge(text: job.status.title, tone: job.status.tone)
                            Text(job.displayLine).font(BK.Font.caption).foregroundStyle(t.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(JobFormat.relative(job.updatedAt)).font(BK.Font.caption).foregroundStyle(t.tertiary).fixedSize()
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(hovering ? t.secondary : t.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityLabel("\(job.title), \(job.status.title)")
        }
    }
}

// MARK: - Detail

struct JobDetailView: View {
    let job: JobRecord
    let jobs: any JobsSource
    var onBack: () -> Void

    @State private var items: [JobItem] = []
    @State private var events: [ActivityEntry] = []
    @State private var report: String?
    @State private var filter: ItemStatus?
    @State private var search = ""
    @State private var confirmDelete = false
    @State private var actionError: String?
    @State private var exportedTo: [URL] = []

    /// Items rendered at once; the rest stay a filter or search away.
    static let visibleItems = 200

    var body: some View {
        Button(action: onBack) { Label("All jobs", systemImage: "chevron.left") }
            .buttonStyle(BKButtonStyle(kind: .ghost, compact: true))
            .padding(.leading, -8)
        header
        controls
        callouts
        usage
        if let plan = job.plan { planSection(plan) }
        if !items.isEmpty || hasForEach { itemsSection }
        activitySection
        filesSection
        Color.clear.frame(height: 0)
            .onAppear(perform: reload)
            .onChange(of: job.updatedAt) { _, _ in reload() }
            // While the job runs, also poll: items are persisted between record updates.
            // `.task` ends when the page closes or the job stops running.
            .task(id: job.status.isActive) {
                guard job.status.isActive else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    if Task.isCancelled { return }
                    reload()
                }
            }
            .confirmationDialog("Delete “\(NotchApprovalView.short(job.title, max: 60))”?", isPresented: $confirmDelete) {
                Button("Delete job", role: .destructive) {
                    jobs.delete(job.id)
                    onBack()
                }
            } message: {
                Text("The job's record is removed and its folder, with any files it made, moves to the Trash.")
            }
    }

    func reload() {
        items = jobs.items(job.id, limit: 1000)
        events = jobs.events(job.id, limit: 300)
        report = jobs.report(job.id)
    }

    var hasForEach: Bool {
        job.plan?.milestones.contains { $0.steps.contains { if case .forEach = $0.kind { return true } else { return false } } } ?? false
    }

    // MARK: Header and controls

    var header: some View {
        BKThemeReader { t in
            HStack(alignment: .center, spacing: BK.Space.lg) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(job.title).font(BK.Font.title2).foregroundStyle(t.text).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        BKBadge(text: job.status.title, tone: job.status.tone)
                        Text(job.displayLine).font(BK.Font.small).foregroundStyle(t.secondary).lineLimit(2)
                    }
                    if job.instruction != job.title {
                        Text(job.instruction).font(BK.Font.caption).foregroundStyle(t.secondary).lineLimit(3).textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
                if job.usage.itemsTotal > 0 {
                    ZStack {
                        BKJobRing(fraction: job.progressFraction, size: 46, lineWidth: 4.5, trackColor: t.dark ? BK.Palette.n800 : BK.Palette.n200,
                                  dimmed: !job.status.isActive && job.status != .completed)
                        Text("\(Int(((job.progressFraction ?? 0) * 100).rounded()))%")
                            .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(t.text)
                    }
                }
            }
        }
    }

    /// glidectl (or another copy of Glide) is running this job; this window only shows it.
    var elsewhere: Bool { jobs.isRunningElsewhere(job.id) }

    var controls: some View {
        HStack(spacing: 6) {
            let s = job.status
            if elsewhere {
                Label("Running in another Glide process", systemImage: "terminal")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            } else {
                actionButtons(s)
            }
            Spacer(minLength: 8)
            Button(action: export) { Label("Export CSV", systemImage: "square.and.arrow.up") }
                .buttonStyle(BKButtonStyle(kind: .secondary, compact: true))
                .disabled(s == .planning)
            Button { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                .buttonStyle(BKButtonStyle(kind: .ghost, compact: true))
                .disabled(s.isActive || elsewhere)
                .help(s.isActive || elsewhere ? "Pause or stop the job before deleting it." : "Delete this job")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder func actionButtons(_ s: JobStatus) -> some View {
            if s == .awaitingConfirmation {
                Button { jobs.start(job.id) } label: { Label("Start", systemImage: "play.fill") }
                    .buttonStyle(BKButtonStyle(kind: .primary, compact: true))
            }
            if s.canPause {
                Button { jobs.pause(job.id) } label: { Label("Pause", systemImage: "pause.fill") }
                    .buttonStyle(BKButtonStyle(kind: .secondary, compact: true))
            }
            if jobs.canResume(job) {
                Button { jobs.resume(job.id) } label: { Label(s == .waiting ? "Run now" : "Resume", systemImage: "play.fill") }
                    .buttonStyle(BKButtonStyle(kind: s == .waiting ? .secondary : .primary, compact: true))
            }
            if !s.isFinished {
                Button { jobs.stop(job.id) } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(BKButtonStyle(kind: .secondary, compact: true))
            }
            if job.canRetryFailed {
                Button { jobs.retryFailedItems(job.id) } label: { Label("Retry \(job.usage.itemsFailed) failed", systemImage: "arrow.clockwise") }
                    .buttonStyle(BKButtonStyle(kind: .secondary, compact: true))
            }
    }

    @ViewBuilder var callouts: some View {
        if let actionError {
            BKCallout(tone: .danger, icon: "exclamationmark.triangle.fill", title: "Something went wrong", message: actionError) {
                Button("Dismiss") { self.actionError = nil }.buttonStyle(BKButtonStyle(kind: .ghost, compact: true))
            }
        }
        if !exportedTo.isEmpty {
            BKCallout(tone: .success, icon: "checkmark", title: exportedTo.count == 1 ? "Exported" : "Exported \(exportedTo.count) files",
                      message: exportedTo.map(\.path).joined(separator: "\n")) {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(exportedTo) }
                    .buttonStyle(BKButtonStyle(kind: .secondary, compact: true)).fixedSize()
            }
        }
        if job.status == .awaitingConfirmation {
            if let e = job.plan?.estimate {
                BKCallout(tone: .info, icon: "gauge.with.dots.needle.33percent", title: "Estimate: \(JobFormat.estimate(e))",
                          message: (e.notes.isEmpty ? "" : e.notes + " ") + "It starts when you press Start.") {
                    Button("Start") { jobs.start(job.id) }.buttonStyle(BKButtonStyle(kind: .primary, compact: true)).fixedSize()
                }
            } else {
                BKCallout(tone: .info, icon: "play.circle", title: "Ready to start", message: "Review the plan below, then press Start.")
            }
        }
        if let wake = jobs.wakeTime(job) {
            BKCallout(tone: .neutral, icon: "moon.zzz.fill", title: "Continues \(JobFormat.when(wake))",
                      message: "The job is sleeping and uses nothing until then. Glide needs to be running at that time.")
        } else if job.status == .waiting, jobs.isQueued(job.id) {
            BKCallout(tone: .neutral, icon: "hourglass", title: "Queued",
                      message: "Other jobs are using every slot (Settings › Jobs). This one starts by itself when one of them finishes.")
        }
        if let err = job.lastError, !err.isEmpty, job.status == .failed || job.status == .needsInput || job.status == .paused {
            BKCallout(tone: job.status == .failed ? .danger : .warning, icon: job.status == .failed ? "xmark.octagon.fill" : "hand.raised.fill",
                      title: job.status == .failed ? "The job failed" : "The job stopped to ask you", message: err)
        }
        if job.status == .completed, let summary = job.summary, !summary.isEmpty {
            BKCallout(tone: .success, icon: "flag.checkered", title: "Done", message: summary)
        }
    }

    // MARK: Usage

    var usage: some View {
        let u = job.usage
        return VStack(alignment: .leading, spacing: BK.Space.md) {
            BKGroupHeader(title: "Usage")
            BKGroup {
                HStack(alignment: .top, spacing: 0) {
                    StatCell(label: "Active time", value: JobFormat.duration(u.activeSeconds))
                    StatCell(label: "Items", value: u.itemsTotal > 0 ? "\(u.itemsDone) of \(u.itemsTotal)" : "—",
                             note: u.itemsFailed > 0 ? "\(u.itemsFailed) failed" : (u.itemsSkipped > 0 ? "\(u.itemsSkipped) skipped" : nil),
                             noteTone: u.itemsFailed > 0 ? .danger : .neutral)
                    StatCell(label: "Model calls", value: "\(u.modelCalls)", note: job.budget.maxModelCalls.map { "of \($0)" })
                    StatCell(label: "Tokens", value: JobFormat.tokens(u.inputTokens + u.outputTokens),
                             note: "\(JobFormat.tokens(u.inputTokens)) in · \(JobFormat.tokens(u.outputTokens)) out")
                    StatCell(label: "Cost", value: JobFormat.cost(u.costUSD, known: u.costKnown),
                             note: job.budget.maxCostUSD.map { "of \(JobFormat.cost($0)) budget" })
                    StatCell(label: "Tools", value: "\(u.toolCalls + u.actions)", note: u.actions > 0 ? "\(u.actions) on screen" : nil)
                }
            }
        }
    }

    // MARK: Plan

    func planSection(_ plan: JobPlan) -> some View {
        let counts = itemCounts
        return VStack(alignment: .leading, spacing: BK.Space.md) {
            BKGroupHeader(title: "Plan", subtitle: plan.outputs.isEmpty ? plan.goal : "\(plan.goal) — \(plan.outputs)")
            BKGroup {
                ForEach(Array(plan.milestones.enumerated()), id: \.offset) { i, milestone in
                    MilestoneRow(milestone: milestone, index: i, job: job, itemCounts: counts)
                }
            }
        }
    }

    // MARK: Items

    var itemCounts: [Int: (done: Int, total: Int)] {
        var counts: [Int: (done: Int, total: Int)] = [:]
        for item in items {
            var c = counts[item.stepID] ?? (0, 0)
            c.total += 1
            if item.status == .done || item.status == .skipped || item.status == .failed { c.done += 1 }
            counts[item.stepID] = c
        }
        return counts
    }

    /// Result columns in the plan's order (for "key result fields"), by forEach step id.
    var outputColumns: [Int: [String]] {
        var map: [Int: [String]] = [:]
        for m in job.plan?.milestones ?? [] {
            for s in m.steps {
                if case .forEach(let spec) = s.kind {
                    map[s.id] = spec.outputColumns.isEmpty ? spec.recipe.flatMap(\.outputFields) : spec.outputColumns
                }
            }
        }
        return map
    }

    var filteredItems: [JobItem] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return items.filter { item in
            if let filter, item.status != filter { return false }
            guard !q.isEmpty else { return true }
            if item.title.lowercased().contains(q) { return true }
            if let e = item.error, e.lowercased().contains(q) { return true }
            if let r = item.result, r.jsonString().lowercased().contains(q) { return true }
            return false
        }
    }

    var itemsSection: some View {
        let byStatus = Dictionary(grouping: items, by: \.status).mapValues(\.count)
        let shown = filteredItems
        let columns = outputColumns
        return VStack(alignment: .leading, spacing: BK.Space.md) {
            BKGroupHeader(title: "Items", subtitle: items.isEmpty ? nil : "\(items.count) item\(items.count == 1 ? "" : "s"), with what the job found for each.") {
                BKSearchField(placeholder: "Search items", text: $search).frame(width: 210)
            }
            if items.isEmpty {
                BKEmptyState(icon: "list.bullet.rectangle", title: "No items yet", message: "Items appear when the job reaches its “for each” step.")
            } else {
                HStack(spacing: 4) {
                    BKPill(title: "All", count: items.count, selected: filter == nil) { filter = nil }
                    ForEach([ItemStatus.done, .failed, .running, .pending, .skipped], id: \.self) { s in
                        if let n = byStatus[s], n > 0 {
                            BKPill(title: s.title, count: n, selected: filter == s) { filter = filter == s ? nil : s }
                        }
                    }
                }
                BKGroup(padding: EdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12)) {
                    ItemHeaderRow()
                    ForEach(shown.prefix(Self.visibleItems)) { item in
                        ItemRow(item: item, columns: columns[item.stepID] ?? [])
                    }
                    if shown.isEmpty {
                        Text("No items match.").font(BK.Font.caption).foregroundStyle(.secondary)
                    } else if shown.count > Self.visibleItems {
                        Text("Showing \(Self.visibleItems) of \(shown.count). Search or filter to find the rest, or export the results as CSV.")
                            .font(BK.Font.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Activity and files

    var activitySection: some View {
        VStack(alignment: .leading, spacing: BK.Space.md) {
            BKGroupHeader(title: "Activity", subtitle: events.count > 120 ? "The latest 120 events." : nil)
            if events.isEmpty {
                BKEmptyState(icon: "text.alignleft", title: "Nothing logged yet")
            } else {
                BKCard(padding: 14) {
                    BKTimeline(entries: Array(events.suffix(120)), onDark: false)
                }
            }
        }
    }

    var filesSection: some View {
        let folder = URL(fileURLWithPath: job.folder, isDirectory: true)
        let reportURL = JobReport.url(folder: job.folder)
        let folderExists = FileManager.default.fileExists(atPath: folder.path)
        return VStack(alignment: .leading, spacing: BK.Space.md) {
            BKGroupHeader(title: "Files")
            BKGroup {
                BKFormRow(title: "Job folder", detail: job.folder) {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                        .buttonStyle(BKButtonStyle(kind: .secondary, compact: true)).fixedSize()
                        .disabled(!folderExists)
                }
                BKFormRow(title: "Report", detail: report == nil ? "Written when the job finishes." : "report.md") {
                    Button("Open") { NSWorkspace.shared.open(reportURL) }
                        .buttonStyle(BKButtonStyle(kind: .secondary, compact: true)).fixedSize()
                        .disabled(report == nil || !FileManager.default.fileExists(atPath: reportURL.path))
                }
            }
            if let report {
                BKCard(padding: 18) { MarkdownPreview(text: report) }
            }
        }
    }

    func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = Self.fileName(job.title) + ".csv"
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        let id = job.id
        let source = jobs
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                do {
                    exportedTo = try source.exportResultFiles(id, to: url)
                    actionError = nil
                } catch {
                    exportedTo = []
                    actionError = "Couldn't export the results: \(error.localizedDescription)"
                }
            }
        }
    }

    /// A safe default file name from the job title.
    static func fileName(_ title: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>\n\r\t")).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let short = String(cleaned.prefix(60)).trimmingCharacters(in: .whitespaces)
        return short.isEmpty ? "Job results" : short
    }
}

extension ItemStatus {
    var title: String {
        switch self {
        case .pending: return "Pending"
        case .running: return "Running"
        case .done: return "Done"
        case .failed: return "Failed"
        case .skipped: return "Skipped"
        }
    }

    var tone: BK.Tone {
        switch self {
        case .pending, .skipped: return .neutral
        case .running: return .info
        case .done: return .success
        case .failed: return .danger
        }
    }
}

private struct StatCell: View {
    let label: String
    let value: String
    var note: String? = nil
    var noteTone: BK.Tone = .neutral

    var body: some View {
        BKThemeReader { t in
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(BK.Font.caption).foregroundStyle(t.secondary)
                Text(value).font(.system(size: 15, weight: .semibold).monospacedDigit()).foregroundStyle(t.text).lineLimit(1).minimumScaleFactor(0.8)
                if let note {
                    Text(note).font(.system(size: 10.5)).foregroundStyle(noteTone == .neutral ? t.tertiary : noteTone.color).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Milestones

private struct MilestoneRow: View {
    let milestone: Milestone
    let index: Int
    let job: JobRecord
    let itemCounts: [Int: (done: Int, total: Int)]

    enum Progress { case done, current, pending }

    var state: Progress {
        if job.status == .completed || index < job.cursor.milestoneIndex { return .done }
        return index == job.cursor.milestoneIndex ? .current : .pending
    }

    func stepState(_ j: Int) -> Progress {
        switch state {
        case .done: return .done
        case .pending: return .pending
        case .current: return j < job.cursor.stepIndex ? .done : (j == job.cursor.stepIndex ? .current : .pending)
        }
    }

    var body: some View {
        BKThemeReader { t in
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    marker(state, t, size: 15)
                    Text(milestone.title).font(BK.Font.bodyMedium).foregroundStyle(state == .pending ? t.secondary : t.text).lineLimit(1)
                    if milestone.requiresApproval { BKBadge(text: "Asks first", tone: .warning, icon: "hand.raised.fill") }
                    Spacer(minLength: 6)
                    let done = (0..<milestone.steps.count).filter { stepState($0) == .done }.count
                    Text("\(done)/\(milestone.steps.count) steps").font(BK.Font.caption).foregroundStyle(t.tertiary)
                }
                if !milestone.description.isEmpty && state != .done {
                    Text(milestone.description).font(BK.Font.caption).foregroundStyle(t.secondary).padding(.leading, 23)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(milestone.steps.enumerated()), id: \.offset) { j, step in
                    HStack(spacing: 8) {
                        marker(stepState(j), t, size: 12)
                        Text(step.title).font(BK.Font.small).foregroundStyle(stepState(j) == .current ? t.text : t.secondary).lineLimit(1)
                        Spacer(minLength: 6)
                        kindBadge(step)
                    }
                    .padding(.leading, 23)
                }
            }
        }
    }

    @ViewBuilder func kindBadge(_ step: JobStep) -> some View {
        switch step.kind {
        case .action(let r):
            HStack(spacing: 4) {
                if r.risk == .high { BKBadge(text: "Approval", tone: .warning) }
                BKBadge(text: r.route.rawValue.capitalized, tone: r.route.needsScreen ? .accent : .info)
            }
        case .forEach(let spec):
            let c = itemCounts[step.id]
            let total = c?.total ?? spec.limit ?? 0
            BKBadge(text: total > 0 ? "For each \(spec.itemLabel) · \(c?.done ?? 0)/\(total)" : "For each \(spec.itemLabel)",
                    tone: .info, icon: "repeat")
        case .wait(let w):
            BKBadge(text: Self.describe(w), tone: .neutral, icon: "clock")
        }
    }

    static func describe(_ w: WaitSpec) -> String {
        switch w {
        case .duration(let s): return "Wait \(JobFormat.duration(s))"
        case .until(let d): return "Until \(d.formatted(date: .abbreviated, time: .shortened))"
        case .daily(let h, let m, let times):
            let time = String(format: "%02d:%02d", min(max(h, 0), 23), min(max(m, 0), 59))
            return times.map { "Daily at \(time) · \($0)×" } ?? "Daily at \(time)"
        case .condition(let check, _, _):
            return "Until \(check.count > 28 ? String(check.prefix(27)) + "…" : check)"
        }
    }

    @ViewBuilder func marker(_ s: Progress, _ t: BKTheme, size: CGFloat) -> some View {
        switch s {
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.system(size: size)).foregroundStyle(BK.Tone.success.color).frame(width: size, height: size)
        case .current:
            if job.status == .running {
                BKProgressRing(size: size, trackColor: t.dark ? BK.Palette.n800 : BK.Palette.n200)
            } else if job.status == .failed {
                Image(systemName: "xmark.circle.fill").font(.system(size: size)).foregroundStyle(BK.Tone.danger.color).frame(width: size, height: size)
            } else {
                Image(systemName: "pause.circle.fill").font(.system(size: size)).foregroundStyle(BK.Tone.warning.color).frame(width: size, height: size)
            }
        case .pending:
            Circle().strokeBorder(t.borderStrong, style: StrokeStyle(lineWidth: 1.2, dash: [2.2, 2.2])).frame(width: size, height: size)
        }
    }
}

// MARK: - Items table

private enum ItemColumns {
    static let index: CGFloat = 34
    static let status: CGFloat = 76
    static let title: CGFloat = 190
}

private struct ItemHeaderRow: View {
    var body: some View {
        BKThemeReader { t in
            HStack(spacing: 10) {
                Text("#").frame(width: ItemColumns.index, alignment: .leading)
                Text("Item").frame(width: ItemColumns.title, alignment: .leading)
                Text("Status").frame(width: ItemColumns.status, alignment: .leading)
                Text("Result").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(BK.Font.micro).foregroundStyle(t.tertiary).textCase(.uppercase)
        }
    }
}

private struct ItemRow: View {
    let item: JobItem
    let columns: [String]

    var body: some View {
        BKThemeReader { t in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(item.index + 1)").font(BK.Font.caption.monospacedDigit()).foregroundStyle(t.tertiary)
                    .frame(width: ItemColumns.index, alignment: .leading)
                Text(item.title.isEmpty ? "Item \(item.index + 1)" : item.title).font(BK.Font.small).foregroundStyle(t.text).lineLimit(2)
                    .frame(width: ItemColumns.title, alignment: .leading)
                HStack(spacing: 3) {
                    BKBadge(text: item.status.title, tone: item.status.tone)
                    if item.attempts > 1 { Text("×\(item.attempts)").font(.system(size: 10)).foregroundStyle(t.tertiary) }
                }
                .frame(width: ItemColumns.status, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    let fields = keyFields
                    if !fields.isEmpty {
                        Text(fields.map { "\($0.0): \($0.1)" }.joined(separator: "  ·  "))
                            .font(BK.Font.caption).foregroundStyle(t.secondary).lineLimit(2).textSelection(.enabled)
                    }
                    if let error = item.error, !error.isEmpty {
                        Text(error).font(BK.Font.caption).foregroundStyle(BK.Tone.danger.color).lineLimit(2).textSelection(.enabled)
                    } else if fields.isEmpty {
                        Text("—").font(BK.Font.caption).foregroundStyle(t.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Up to three result fields: the plan's output columns first, then the rest by name.
    var keyFields: [(String, String)] {
        guard let object = item.result?.objectValue, !object.isEmpty else { return [] }
        let ordered = columns.filter { object[$0] != nil } + object.keys.filter { !columns.contains($0) }.sorted()
        return ordered.prefix(3).compactMap { key in
            guard let v = object[key], !v.isNull else { return nil }
            let text = (v.stringValue ?? v.jsonString()).replacingOccurrences(of: "\n", with: " ")
            return (key, text.count > 70 ? String(text.prefix(69)) + "…" : text)
        }
    }
}

// MARK: - Report preview

/// Light Markdown rendering for report previews: headings, bullets and inline styles.
/// (SwiftUI's Markdown support is inline-only, so block structure is handled here.)
struct MarkdownPreview: View {
    let text: String
    /// Long reports are cut in the preview; "Open" shows the whole file.
    static let maxLines = 400

    var body: some View {
        BKThemeReader { t in
            let lines = text.components(separatedBy: .newlines)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(lines.prefix(Self.maxLines).enumerated()), id: \.offset) { _, raw in
                    line(raw, t)
                }
                if lines.count > Self.maxLines {
                    Text("…").font(BK.Font.small).foregroundStyle(t.tertiary)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder func line(_ raw: String, _ t: BKTheme) -> some View {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty {
            Color.clear.frame(height: 2)
        } else if s.hasPrefix("#") {
            let level = s.prefix { $0 == "#" }.count
            let title = s.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            inline(title).font(level <= 1 ? BK.Font.title2 : (level == 2 ? BK.Font.headline : BK.Font.bodyMedium))
                .foregroundStyle(t.text).padding(.top, level <= 2 ? 6 : 2)
        } else if s.hasPrefix("- ") || s.hasPrefix("* ") || s.hasPrefix("• ") {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("•").foregroundStyle(t.tertiary)
                inline(String(s.dropFirst(2))).foregroundStyle(t.text)
            }
            .font(BK.Font.body)
            .padding(.leading, raw.prefix { $0 == " " }.count >= 2 ? 16 : 0)
        } else if s.hasPrefix("|") {
            Text(s).font(BK.Font.mono).foregroundStyle(t.secondary)
        } else {
            inline(s).font(BK.Font.body).foregroundStyle(t.text).fixedSize(horizontal: false, vertical: true)
        }
    }

    func inline(_ s: String) -> Text {
        if let a = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(a)
        }
        return Text(s)
    }
}

// MARK: - Defaults

private struct JobDefaultsSection: View {
    @Bindable var store: SettingsStore

    var body: some View {
        BKGroupHeader(title: "Screen and resources", subtitle: "Most job steps run in the background. These settings cover the ones that need your screen, and your Mac.")
        BKGroup {
            BKFormRow(title: "Use the screen", detail: screenDetail) {
                BKMenu(options: ScreenUse.allCases.map { ($0, $0.title) }, selection: $store.settings.jobs.screenUse, minWidth: 170)
            }
            if store.settings.jobs.screenUse == .whenIdle {
                BKFormRow(title: "Idle for at least", detail: "How long you must leave the mouse and keyboard alone before a job borrows them.") {
                    BKStepper(value: $store.settings.jobs.idleSeconds, range: 10...600, step: 10) { JobFormat.duration($0) }
                }
            }
            BKFormRow(title: "Jobs at once", detail: "Extra jobs wait in line. On-screen steps never run at the same time.") {
                BKStepper(value: $store.settings.jobs.maxConcurrentJobs, range: 1...4)
            }
            BKFormRow(title: "Resume interrupted jobs", detail: "Continue jobs that were running when Glide quit. Off: they wait, paused, for you.") {
                BKSwitch(isOn: $store.settings.jobs.autoResume, label: "Resume interrupted jobs")
            }
            BKFormRow(title: "Keep my Mac awake", detail: "Prevent idle sleep while a job runs. The display can still turn off.") {
                BKSwitch(isOn: $store.settings.jobs.keepAwake, label: "Keep my Mac awake")
            }
            BKFormRow(title: "Notifications", detail: "Tell me when a job finishes or needs me and the notch is closed.") {
                BKSwitch(isOn: $store.settings.jobs.notifications, label: "Notifications")
            }
        }

        BKGroupHeader(title: "Default budget", subtitle: "A job pauses and asks you before going past any of these. Turn a limit off to remove it.")
        BKGroup {
            OptionalLimitRow(title: "Cost", value: $store.settings.jobs.defaultBudget.maxCostUSD, fallback: 5, range: 0.5...100, step: 0.5) { JobFormat.cost($0) }
            OptionalLimitRow(title: "Running time", value: $store.settings.jobs.defaultBudget.maxDurationSeconds, fallback: 4 * 3600,
                             range: 900...(48 * 3600), step: 900) { JobFormat.duration($0) }
            OptionalLimitRow(title: "Model calls",
                             value: Binding(get: { store.settings.jobs.defaultBudget.maxModelCalls.map(Double.init) },
                                            set: { store.settings.jobs.defaultBudget.maxModelCalls = $0.map { Int($0) } }),
                             fallback: 2000, range: 100...20000, step: 100) { String(Int($0)) }
            BKFormRow(title: "Attempts per item", detail: "Tries before an item is marked failed and the job moves on.") {
                BKStepper(value: $store.settings.jobs.defaultBudget.maxItemAttempts, range: 1...5)
            }
            BKFormRow(title: "Pause when failures pass", detail: "Share of failed items (after at least 5) that pauses the job to ask what's wrong.") {
                BKStepper(value: Binding(get: { store.settings.jobs.defaultBudget.maxFailureRate * 100 },
                                         set: { store.settings.jobs.defaultBudget.maxFailureRate = $0 / 100 }),
                          range: 10...100, step: 5) { "\(Int($0))%" }
            }
        }

        BKGroupHeader(title: "Ask before starting", subtitle: "Jobs estimated above either limit wait for you to press Start. Smaller jobs start right away.")
        BKGroup {
            BKFormRow(title: "Estimated cost above") {
                BKStepper(value: $store.settings.jobs.confirmAboveCostUSD, range: 0...50, step: 0.25) { JobFormat.cost($0) }
            }
            BKFormRow(title: "Estimated time above") {
                BKStepper(value: $store.settings.jobs.confirmAboveMinutes, range: 1...240, step: 5) { JobFormat.minutes($0) }
            }
        }
    }

    var screenDetail: String {
        switch store.settings.jobs.screenUse {
        case .always: return "Jobs may move the cursor whenever an on-screen step comes up."
        case .whenIdle: return "On-screen steps wait until you step away from the Mac."
        case .never: return "On-screen steps pause the job and ask you."
        }
    }
}

/// A limit that can be turned off (nil): a switch plus a stepper.
private struct OptionalLimitRow: View {
    let title: String
    @Binding var value: Double?
    let fallback: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var format: (Double) -> String

    var body: some View {
        BKFormRow(title: title, detail: value == nil ? "No limit" : nil) {
            HStack(spacing: 10) {
                BKStepper(value: Binding(get: { min(max(value ?? fallback, range.lowerBound), range.upperBound) }, set: { value = $0 }),
                          range: range, step: step, format: format)
                    .disabled(value == nil)
                    .opacity(value == nil ? 0.5 : 1)
                BKSwitch(isOn: Binding(get: { value != nil }, set: { value = $0 ? fallback : nil }), label: "Limit \(title.lowercased())")
            }
        }
    }
}
