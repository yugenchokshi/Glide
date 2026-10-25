import SwiftUI
import AgentKit
import AutomationKit

/// Hardware-notch silhouette: flat top that flares outward, rounded bottom corners.
struct NotchShape: Shape {
    var topRadius: CGFloat = 6
    var bottomRadius: CGFloat = 14

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let t = topRadius, b = min(bottomRadius, rect.height / 2)
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t), control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY), control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b), control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

struct NotchRootView: View {
    @Bindable var model: NotchModel

    var body: some View {
        let size = model.size
        let expanded = model.presentation != .idle && model.presentation != .hover
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(topRadius: expanded ? 10 : 6, bottomRadius: expanded ? 22 : 10)
                    .fill(BK.Notch.surface)
                    .shadow(color: .black.opacity(expanded ? 0.45 : 0), radius: 12, y: 6)
                content
                    .padding(.horizontal, expanded ? 22 : 10)
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .clipShape(NotchShape(topRadius: expanded ? 10 : 6, bottomRadius: expanded ? 22 : 10))
            }
            .frame(width: size.width, height: size.height)
            .contentShape(NotchShape())
            .onHover { h in
                model.hovering = h
                model.recompute()
            }
            .onTapGesture {
                if model.presentation == .idle || model.presentation == .hover { model.open() }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: model.presentation)
        .environment(\.colorScheme, .dark)
        .environment(\.bkForceDark, true)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder var content: some View {
        VStack(spacing: 0) {
            topWings.frame(height: model.geometry.notchRect.height)
            switch model.presentation {
            case .idle, .hover: EmptyView()
            case .input: NotchInputView(model: model).transition(.opacity.combined(with: .move(edge: .top)))
            case .running: NotchRunningView(model: model).transition(.opacity)
            case .detail: NotchDetailView(model: model).transition(.opacity)
            case .approval: NotchApprovalView(model: model).transition(.opacity)
            case .result: NotchResultView(model: model).transition(.opacity)
            case .job: NotchJobCard(model: model).transition(.opacity)
            case .listening: NotchListeningView(model: model).transition(.opacity.combined(with: .move(edge: .top)))
            case .thinking: NotchThinkingView().transition(.opacity)
            case .speaking: NotchSpeakingView(model: model).transition(.opacity)
            case .question: NotchQuestionView(model: model).transition(.opacity)
            }
        }
    }

    /// Content on either side of the physical notch (never under it).
    @ViewBuilder var topWings: some View {
        let c = model.controller
        let wingJob = model.wingJob
        HStack {
            if model.presentation != .idle {
                HStack(spacing: 6) {
                    BKAgentOrb(mode: orbMode, size: 14)
                    if model.presentation == .hover && !c.isRunning && wingJob == nil {
                        Text("Glide").font(.system(size: 11, weight: .semibold)).foregroundStyle(BK.Notch.secondary)
                    }
                }
            } else if c.isRunning {
                BKAgentOrb(mode: orbMode, size: 12)
            } else if wingJob != nil {
                // Static (idle) orb: it sits in the menu bar for as long as the job runs.
                BKAgentOrb(mode: .idle, size: 10)
            }
            Spacer()
            if model.voice.micLive && model.presentation != .listening {
                // Listening for an answer or an interruption: the microphone is never on unseen.
                MicIndicator()
            } else if c.isRunning, let plan = c.plan, model.presentation != .idle {
                Text("\(min(c.currentStepIndex + 1, plan.steps.count))/\(plan.steps.count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(BK.Notch.secondary)
            } else if let wingJob {
                NotchJobWing(job: wingJob, showCount: model.isExpanded)
            } else if model.presentation == .hover {
                BKKeyCap(text: model.settings.settings.hotkeys.open.display, onDark: true)
            }
        }
        .padding(.horizontal, model.geometry.hasNotch ? 0 : 6)
    }

    var orbMode: BKAgentOrb.Mode {
        switch model.presentation {
        case .listening, .thinking: return .thinking
        case .speaking where model.voice.isSpeaking: return .acting
        default: break
        }
        switch model.controller.phase {
        case .planning: return .thinking
        case .executing: return .acting
        case .awaitingApproval, .paused: return .paused
        case .completed: return .success
        case .failed, .needsInput: return .error
        default: return .idle
        }
    }
}

// MARK: - Input (State B)

struct NotchInputView: View {
    @Bindable var model: NotchModel
    @FocusState private var focused: Bool
    @State private var recents: [TaskRecord] = []

    var empty: Bool { model.inputText.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.controller.isConfigured {
                HStack(spacing: 10) {
                    let chip = BK.Tone.warning.chip(dark: true)
                    Image(systemName: "key.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(chip.text)
                        .frame(width: 24, height: 24).background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(chip.background))
                    Text("Add an OpenAI or Anthropic key to get started.").font(.system(size: 12)).foregroundStyle(BK.Notch.secondary)
                    Spacer()
                    Button("Open Settings") { model.openSettings("providers") }.buttonStyle(BKButtonStyle(kind: .secondary, compact: true, onDark: true))
                }
                .padding(7)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(BK.Notch.raised))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(BK.Notch.border))
            }
            HStack(spacing: 10) {
                TextField("", text: $model.inputText, prompt: Text("What should I do?").foregroundStyle(BK.Notch.tertiary), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(BK.Notch.text)
                    .lineLimit(1...3)
                    .focused($focused)
                    .onSubmit { model.submit() }
                    .onKeyPress(.escape) { model.close(); return .handled }
                    .accessibilityLabel("Task")
                BKIconButton(systemName: "mic.fill", help: "Talk instead", size: 30) { model.startListening() }
                Button { model.submit() } label: {
                    Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(empty ? AnyShapeStyle(BK.Palette.n700) : AnyShapeStyle(BK.accentGradient)))
                        .overlay(Circle().strokeBorder(LinearGradient(colors: [.white.opacity(empty ? 0.08 : 0.3), .clear], startPoint: .top, endPoint: .center), lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(empty)
                .keyboardShortcut(.return, modifiers: [])
                .help("Start")
                .accessibilityLabel("Start")
            }
            .padding(.leading, 14).padding(.trailing, 7).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(BK.Notch.field))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(BK.Notch.border))

            if let job = model.pillJob {
                NotchJobRow(model: model, job: job, pill: true)
            }

            if let notice = model.voice.notice {
                HStack(spacing: 8) {
                    Image(systemName: "mic.slash.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(BK.Tone.warning.color)
                    Text(notice).font(.system(size: 11.5)).foregroundStyle(BK.Notch.secondary).lineLimit(2)
                    Spacer(minLength: 0)
                    if notice == OnDeviceRecognizer.micOffMessage {
                        Button("Open Settings") { NSWorkspace.shared.open(VoicePermissions.Kind.microphone.settingsURL) }
                            .buttonStyle(BKButtonStyle(kind: .secondary, compact: true, onDark: true))
                    }
                }
                .frame(height: 26)
            } else {
                recentsRow
            }
        }
        .padding(.top, 8)
        .onAppear {
            var seen = Set<String>()
            recents = SnapshotRenderer.isRendering ? [] : LocalStore.shared.recentTasks(limit: 20).filter { $0.status == "completed" && seen.insert($0.instruction).inserted }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
        }
        .onChange(of: model.focusToken) { _, _ in focused = true }
        .onDisappear { model.voice.clearNotice() }
    }

    var recentsRow: some View {
        HStack(spacing: 6) {
            ForEach(recents.prefix(3)) { r in
                Button { model.inputText = r.instruction } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.counterclockwise").font(.system(size: 9, weight: .bold)).foregroundStyle(BK.Notch.tertiary)
                        Text(r.instruction).lineLimit(1).font(.system(size: 11.5)).foregroundStyle(BK.Notch.secondary)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Capsule().fill(BK.Notch.raised))
                    .overlay(Capsule().strokeBorder(BK.Notch.border))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: 170)
            }
            Spacer()
            BKIconButton(systemName: "clock.arrow.circlepath", help: "Recent tasks") {
                model.historyOpen = true
                model.recompute()
            }
            BKIconButton(systemName: "gearshape.fill", help: "Settings") { model.openSettings(nil) }
        }
    }
}

// MARK: - Running (States C/D)

struct NotchRunningView: View {
    @Bindable var model: NotchModel

    var body: some View {
        let c = model.controller
        HStack(spacing: 10) {
            if c.phase == .planning {
                BKShimmerText(text: c.status.isEmpty ? "Understanding your task…" : c.status)
            } else {
                // What Glide just said, while it's on show; otherwise the task's status.
                let line = model.voice.caption ?? c.status
                Text(line).font(.system(size: 13, weight: .medium)).foregroundStyle(BK.Notch.text).lineLimit(1)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: line)
            }
            Spacer(minLength: 6)
            if model.jobApprovalWaiting {
                // Held back while this task clicks on screen; the card shows when the task is done.
                Image(systemName: "hand.raised.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(BK.Tone.warning.color)
                    .help("A background job is waiting for your OK. It shows when this task is done.")
                    .accessibilityLabel("A background job is waiting for your OK")
            }
            if c.phase == .planning {
                Button("Cancel") { c.stop() }.buttonStyle(BKButtonStyle(kind: .secondary, compact: true, onDark: true))
            } else {
                BKIconButton(systemName: c.phase == .paused ? "play.fill" : "pause.fill", help: c.phase == .paused ? "Resume" : "Pause") { model.togglePause() }
                BKIconButton(systemName: "stop.fill", help: "Stop now", tone: .danger) { c.stop() }
            }
            BKIconButton(systemName: "chevron.down", help: "Show details") {
                model.detailOpen = true
                model.recompute()
            }
        }
        .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(BK.Notch.field))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(BK.Notch.border))
        .bkIridescentRim(c.phase == .planning || c.phase == .executing, cornerRadius: 14)
        .padding(.top, 6)
    }
}

// MARK: - Detail / history

struct NotchDetailView: View {
    @Bindable var model: NotchModel
    @State private var selectedTask: TaskRecord?
    @State private var tasks: [TaskRecord] = []
    @State private var events: [ActivityEntry] = []

    var body: some View {
        let c = model.controller
        // With no quick task to show, the detail view is the background jobs list.
        let showTask = c.isRunning || (!model.jobsDetailOpen && (c.plan != nil || !c.activity.isEmpty))
        let hasJobs = !model.jobs.unfinishedJobs.isEmpty
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.historyOpen ? "Recent tasks" : (!showTask ? "Background jobs" : (c.instruction.isEmpty ? "Activity" : c.instruction)))
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(BK.Notch.text).lineLimit(2)
                Spacer()
                if c.isRunning {
                    BKIconButton(systemName: c.phase == .paused ? "play.fill" : "pause.fill", help: c.phase == .paused ? "Resume" : "Pause") { model.togglePause() }
                    BKIconButton(systemName: "stop.fill", help: "Stop now", tone: .danger) { c.stop() }
                }
                BKIconButton(systemName: "chevron.up", help: "Collapse") {
                    model.detailOpen = false
                    model.historyOpen = false
                    model.jobsDetailOpen = false
                    if !c.isRunning && !model.resultVisible { model.inputOpen = false }
                    model.recompute()
                }
            }
            if model.historyOpen {
                historyList
            } else if !showTask {
                NotchJobsSection(model: model, compact: false)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    if let plan = c.plan {
                        BKPlanProgress(plan: plan, currentIndex: c.currentStepIndex, finished: c.phase == .completed)
                            .frame(width: 190, alignment: .leading)
                    }
                    ScrollViewReader { proxy in
                        ScrollView {
                            BKTimeline(entries: c.activity).padding(.trailing, 6)
                            Color.clear.frame(height: 1).id("end")
                        }
                        .onChange(of: c.activity.count) { _, _ in withAnimation { proxy.scrollTo("end") } }
                    }
                }
                if hasJobs {
                    Rectangle().fill(BK.Notch.border).frame(height: 1)
                    NotchJobsSection(model: model, compact: true)
                }
            }
        }
        .padding(.top, 8).padding(.bottom, 14)
    }

    @ViewBuilder var historyList: some View {
        HStack(alignment: .top, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(tasks) { t in
                        Button { selectedTask = t; events = LocalStore.shared.events(taskID: t.id) } label: {
                            HStack(spacing: 6) {
                                BKStatusDot(tone: t.status == "completed" ? .success : (t.status == "running" ? .info : .danger))
                                Text(t.instruction).font(.system(size: 12)).foregroundStyle(BK.Notch.text).lineLimit(1)
                                Spacer()
                            }
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(selectedTask?.id == t.id ? Color.white.opacity(0.1) : .clear))
                        }
                        .buttonStyle(.plain)
                    }
                    if tasks.isEmpty { Text("No tasks yet.").font(.system(size: 12)).foregroundStyle(BK.Notch.tertiary) }
                }
            }
            .frame(width: 230)
            ScrollView {
                if let t = selectedTask {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(t.summary ?? t.error ?? t.status).font(.system(size: 12)).foregroundStyle(BK.Notch.secondary).lineLimit(3)
                            Spacer()
                            Button("Run again") { model.inputText = t.instruction; model.historyOpen = false; model.recompute() }
                                .buttonStyle(BKButtonStyle(kind: .secondary, compact: true, onDark: true))
                        }
                        BKTimeline(entries: events)
                    }
                } else {
                    Text("Select a task to see what Glide did.").font(.system(size: 12)).foregroundStyle(BK.Notch.tertiary)
                }
            }
        }
        .onAppear { tasks = LocalStore.shared.recentTasks(limit: 40) }
    }
}

// MARK: - Approval (State E)

struct NotchApprovalView: View {
    @Bindable var model: NotchModel

    var body: some View {
        // The quick task's approval, or a background job's (answered through JobCenter).
        if let approval = model.activeApproval {
            let req = approval.request
            let job = approval.jobID.flatMap { model.jobs.job($0) }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    let chip = BK.Tone.warning.chip(dark: true)
                    Image(systemName: req.kind == .screenshot ? "eye.trianglebadge.exclamationmark.fill" : "hand.raised.fill")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(chip.text)
                        .frame(width: 26, height: 26).background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(chip.background))
                    Text(req.kind == .screenshot ? "Allow a screenshot?" : "Approve this action?")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(BK.Notch.text)
                    Spacer()
                    BKBadge(text: "\(req.risk.rawValue.capitalized) risk", tone: req.risk == .high ? .danger : .warning)
                }
                Text(req.title).font(.system(size: 14, weight: .medium)).foregroundStyle(BK.Notch.text).lineLimit(2)
                HStack(spacing: 6) {
                    if let job { BKBadge(text: Self.short(job.title), tone: .accent, icon: "square.stack.3d.up.fill") }
                    if let app = req.appName { BKBadge(text: app, tone: .info) }
                    ForEach(req.reasons.prefix(job == nil ? 3 : 2), id: \.self) { BKBadge(text: Self.short($0), tone: .warning) }
                }
                Text(req.detail).font(.system(size: 11.5)).foregroundStyle(BK.Notch.secondary).lineLimit(3)
                // Each button answers the request it was drawn for (see `respondToApproval`).
                HStack {
                    Button(approval.jobID == nil ? "Stop task" : "Stop job") { model.respondToApproval(.stop, to: approval) }
                        .buttonStyle(BKButtonStyle(kind: .ghost, compact: true, onDark: true))
                    Spacer()
                    Button("Reject") { model.respondToApproval(.reject, to: approval) }.buttonStyle(BKButtonStyle(kind: .secondary, compact: false, onDark: true))
                    Button("Approve") { model.respondToApproval(.approve, to: approval) }.buttonStyle(BKButtonStyle(kind: .primary))
                }
            }
            .padding(.top, 8)
            // A new request gets new buttons: a press that began on the previous card is dropped
            // instead of finishing on this one.
            .id(req.id)
        }
    }

    /// Badges never wrap (they're fixed-size), so long job titles and reasons are cut.
    static func short(_ s: String, max: Int = 36) -> String {
        s.count > max ? String(s.prefix(max - 1)) + "…" : s
    }
}

// MARK: - Result (States F/G)

struct NotchResultView: View {
    @Bindable var model: NotchModel

    var body: some View {
        let c = model.controller
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                BKAgentOrb(mode: c.phase == .completed ? .success : (c.phase == .stopped ? .paused : .error), size: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(BK.Notch.text)
                    Text(c.status).font(.system(size: 12)).foregroundStyle(BK.Notch.secondary).lineLimit(3).textSelection(.enabled)
                }
                Spacer()
            }
            HStack {
                Button("View details") { model.detailOpen = true; model.recompute() }
                    .buttonStyle(BKButtonStyle(kind: .ghost, compact: true, onDark: true))
                Spacer()
                if c.phase == .failed || c.phase == .stopped {
                    Button("Retry") { model.resultVisible = false; c.retry(); model.recompute() }.buttonStyle(BKButtonStyle(kind: .secondary, compact: true, onDark: true))
                    Button("Replan") { model.resultVisible = false; c.replan(); model.recompute() }.buttonStyle(BKButtonStyle(kind: .secondary, compact: true, onDark: true))
                }
                if c.phase == .needsInput {
                    Button("Reply") { model.inputText = c.instruction + " — "; model.open() }.buttonStyle(BKButtonStyle(kind: .secondary, compact: true, onDark: true))
                }
                if c.phase == .failed && !c.isConfigured {
                    Button("Open Settings") { model.openSettings("providers") }.buttonStyle(BKButtonStyle(kind: .primary, compact: true))
                }
                Button("Close") { model.close() }.buttonStyle(BKButtonStyle(kind: .secondary, compact: true, onDark: true))
            }
        }
        .padding(.top, 8)
    }

    var title: String {
        switch model.controller.phase {
        case .completed: return "Done"
        case .stopped: return "Stopped"
        case .needsInput: return "Needs your input"
        default: return "Something went wrong"
        }
    }
}
