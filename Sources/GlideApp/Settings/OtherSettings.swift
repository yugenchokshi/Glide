import SwiftUI
import AppKit
import AgentKit
import AutomationKit

// MARK: - Permissions

struct PermissionsSettingsView: View {
    @State private var statuses: [PermissionKind: PermissionStatus] = [:]
    let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        BKSectionHeader(title: "Permissions", subtitle: "macOS asks you to grant these. Glide can't grant them to itself.")
        BKGroup {
            ForEach(PermissionKind.allCases) { kind in
                PermissionRow(kind: kind, status: statuses[kind] ?? .unknown) {
                    Task { statuses[kind] = await PermissionManager.request(kind) }
                }
            }
        }
        Text("After granting Accessibility or Screen Recording, macOS may require relaunching Glide.")
            .font(BK.Font.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
            .onAppear(perform: refresh)
            .onReceive(timer) { _ in refresh() }
    }

    func refresh() {
        for k in PermissionKind.allCases { statuses[k] = PermissionManager.status(k) }
    }
}

struct PermissionRow: View {
    let kind: PermissionKind
    let status: PermissionStatus
    let request: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            BKTile(title: kind.title, color: color, symbol: icon, size: 30)
            BKFormRow(title: kind.title, detail: kind.purpose) {
                HStack(spacing: 8) {
                    switch status {
                    case .granted: BKBadge(text: "Granted", tone: .success, icon: "checkmark")
                    case .denied: BKBadge(text: kind == .accessibility ? "Required" : "Not granted", tone: kind == .accessibility ? .danger : .warning)
                    case .notDetermined: BKBadge(text: "Not granted", tone: .warning)
                    case .unknown: BKBadge(text: "Asked when needed", tone: .neutral)
                    }
                    if status != .granted {
                        Button(kind == .automation ? "Open Settings" : "Grant…", action: request)
                            .buttonStyle(BKButtonStyle(kind: kind == .accessibility ? .primary : .secondary, compact: true))
                            .fixedSize()
                    }
                }
            }
        }
    }

    var icon: String {
        switch kind {
        case .accessibility: return "accessibility"
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .automation: return "gearshape.2.fill"
        case .microphone: return "mic.fill"
        }
    }

    var color: Color {
        switch kind {
        case .accessibility: return BK.Palette.accent500
        case .screenRecording: return Color(hex: 0x8B5CF6)
        case .automation: return Color(hex: 0xF97316)
        case .microphone: return Color(hex: 0xF43F5E)
        }
    }
}

// MARK: - Safety

struct SafetySettingsView: View {
    @Bindable var store: SettingsStore
    @State private var newApp = ""

    var body: some View {
        BKSectionHeader(title: "Safety", subtitle: "High-risk actions (sending, deleting, publishing, purchasing, security changes) always wait for your approval. Password fields and card numbers are never typed.")
        BKGroupHeader(title: "Approvals")
        BKGroup {
            BKFormRow(title: "Ask before", detail: "Actions at or above this level wait for you in the notch.") {
                BKMenu(options: ApprovalLevel.allCases.map { ($0, $0.shortTitle) }, selection: $store.settings.safety.approvalLevel, minWidth: 170)
            }
            BKFormRow(title: "Screenshots to vision models", detail: "Used only when a control isn't exposed to accessibility and local OCR can't find it. Password fields are blacked out first.") {
                BKMenu(options: ScreenshotConsent.allCases.map { ($0, $0.title) }, selection: $store.settings.safety.screenshotConsent, minWidth: 170)
            }
            BKFormRow(title: "Pause when I move the mouse", detail: "Grabbing the mouse during a task pauses the agent instantly.") {
                BKSwitch(isOn: $store.settings.safety.pauseOnUserInput, label: "Pause when I move the mouse")
            }
        }
        BKGroupHeader(title: "Excluded apps", subtitle: "Glide will never read or operate these apps (names or bundle IDs).")
        BKGroup {
            ForEach(store.settings.safety.excludedApps, id: \.self) { app in
                HStack(spacing: 10) {
                    BKTile(title: app, color: BK.Palette.n500, symbol: "nosign", size: 24)
                    Text(app).font(BK.Font.body)
                    Spacer()
                    Button { store.settings.safety.excludedApps.removeAll { $0 == app } } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(BKButtonStyle(kind: .ghost, compact: true))
                    .accessibilityLabel("Remove \(app)")
                }
            }
            HStack(spacing: 6) {
                BKTextField(placeholder: "App name or bundle ID", text: $newApp).onSubmit(add)
                Button("Add", action: add).buttonStyle(BKButtonStyle(kind: .secondary, compact: true)).fixedSize().disabled(newApp.isEmpty)
            }
        }
        BKGroupHeader(title: "Limits", subtitle: "A task stops when it reaches any of these.")
        BKGroup {
            limitRow("Max steps per task", BKStepper(value: $store.settings.limits.maxSteps, range: 3...60))
            limitRow("Max actions per step", BKStepper(value: $store.settings.limits.maxActionsPerStep, range: 3...40))
            limitRow("Max actions per task", BKStepper(value: $store.settings.limits.maxTotalActions, range: 10...300, step: 10))
            limitRow("Retries before giving up", BKStepper(value: $store.settings.limits.retryLimit, range: 0...8))
            limitRow("Replans after failures", BKStepper(value: $store.settings.limits.maxReplans, range: 0...5))
            limitRow("Task timeout", BKStepper(value: $store.settings.limits.taskTimeoutSeconds, range: 60...3600, step: 60) { "\(Int($0 / 60)) min" })
        }
    }

    func limitRow(_ title: String, _ stepper: BKStepper) -> some View {
        BKFormRow(title: title) { stepper }
    }

    func add() {
        let v = newApp.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, !store.settings.safety.excludedApps.contains(v) else { return }
        store.settings.safety.excludedApps.append(v)
        newApp = ""
    }
}

extension ApprovalLevel {
    var shortTitle: String {
        switch self {
        case .highRiskOnly: return "High-risk actions"
        case .mediumAndHigh: return "Medium and high risk"
        case .everyAction: return "Every action"
        }
    }
}

// MARK: - Shortcuts

struct ShortcutsSettingsView: View {
    @Bindable var store: SettingsStore
    var onChange: () -> Void
    var conflicts: () -> [HotkeyManager.Action: String]
    @State private var recording: HotkeyManager.Action?
    @State private var monitor: Any?
    @State private var conflictText: [HotkeyManager.Action: String] = [:]

    var body: some View {
        BKSectionHeader(title: "Shortcuts", subtitle: "Global shortcuts work from any app. The emergency stop works even when Glide's UI is hidden.")
        BKGroup {
            row(.open, "Open Glide", \.open)
            row(.pauseResume, "Pause / resume", \.pauseResume)
            row(.stop, "Emergency stop", \.stop)
        }
        .onAppear { conflictText = conflicts() }
        .onDisappear(perform: endRecording)
    }

    @ViewBuilder func row(_ action: HotkeyManager.Action, _ title: String, _ path: WritableKeyPath<HotkeySettings, HotkeySetting>) -> some View {
        BKFormRow(title: title, detail: conflictText[action]) {
            HStack(spacing: 8) {
                if recording == action {
                    BKBadge(text: "Press keys…", tone: .info)
                } else {
                    BKKeyCap(text: store.settings.hotkeys[keyPath: path].display)
                }
                Button(recording == action ? "Cancel" : "Change") {
                    if recording == action { endRecording() } else { beginRecording(action, path) }
                }.buttonStyle(BKButtonStyle(kind: .secondary, compact: true)).fixedSize()
            }
        }
    }

    func beginRecording(_ action: HotkeyManager.Action, _ path: WritableKeyPath<HotkeySettings, HotkeySetting>) {
        endRecording()
        recording = action
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                endRecording()
                return nil
            }
            if let hk = HotkeySetting.from(event: event) {
                store.settings.hotkeys[keyPath: path] = hk
                endRecording()
                onChange()
                conflictText = conflicts()
            }
            return nil
        }
    }

    func endRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }
}

// MARK: - Skills

struct SkillsSettingsView: View {
    @State private var skills: [Skill] = []
    @State private var editing: Skill?

    var body: some View {
        BKSectionHeader(title: "Skills", subtitle: "Reusable workflows the planner follows when your request matches. Skills store steps in words, never screen coordinates.")
        BKGroupHeader(title: "\(skills.count) skill\(skills.count == 1 ? "" : "s")") {
            Button { editing = Skill(name: "New skill", description: "", triggers: [], steps: []) } label: { Label("New skill", systemImage: "plus") }
                .buttonStyle(BKButtonStyle(kind: .secondary, compact: true)).fixedSize()
        }
        if skills.isEmpty {
            BKEmptyState(icon: "wand.and.stars", title: "No skills yet", message: "Save one from a completed task in History, or create one here.")
        } else {
            BKGroup {
                ForEach(skills) { skill in
                    HStack(alignment: .top, spacing: 11) {
                        BKTile(title: skill.name, color: Color(hex: 0x8B5CF6), symbol: "wand.and.stars", size: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(skill.name).font(BK.Font.bodyMedium)
                                if skill.requiresApproval { BKBadge(text: "Approval", tone: .warning) }
                            }
                            if !skill.description.isEmpty { Text(skill.description).font(BK.Font.caption).foregroundStyle(.secondary).lineLimit(2) }
                            Text(skill.steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
                                .font(BK.Font.caption).foregroundStyle(.secondary).padding(.top, 2)
                        }
                        Spacer()
                        Button("Edit") { editing = skill }.buttonStyle(BKButtonStyle(kind: .secondary, compact: true)).fixedSize()
                    }
                }
            }
        }
        Color.clear.frame(height: 0)
            .onAppear(perform: reload)
            .sheet(item: $editing) { skill in
                SkillEditor(skill: skill, onSave: { s in LocalStore.shared.saveSkill(s); editing = nil; reload() },
                            onDelete: { LocalStore.shared.deleteSkill(id: skill.id); editing = nil; reload() },
                            onCancel: { editing = nil })
            }
    }

    func reload() { skills = LocalStore.shared.skills() }
}

struct SkillEditor: View {
    @State var skill: Skill
    var onSave: (Skill) -> Void
    var onDelete: () -> Void
    var onCancel: () -> Void
    @State private var triggers = ""
    @State private var steps = ""
    @State private var params = ""
    @State private var apps = ""

    var body: some View {
        BKThemeReader { t in
            VStack(alignment: .leading, spacing: 12) {
                Text("Skill").font(BK.Font.title2)
                BKGroup {
                    BKFormRow(title: "Name") { BKTextField(placeholder: "Meeting note", text: $skill.name).frame(width: 300) }
                    BKFormRow(title: "Description") { BKTextField(placeholder: "What it does", text: $skill.description).frame(width: 300) }
                    BKFormRow(title: "Triggers", detail: "Comma-separated phrases") { BKTextField(placeholder: "meeting note, standup notes", text: $triggers).frame(width: 300) }
                    BKFormRow(title: "Parameters", detail: "Comma-separated") { BKTextField(placeholder: "topic, attendees", text: $params).frame(width: 300) }
                    BKFormRow(title: "Preconditions") { BKTextField(placeholder: "Notes is installed", text: $skill.preconditions).frame(width: 300) }
                    BKFormRow(title: "Apps") { BKTextField(placeholder: "Notes", text: $apps).frame(width: 300) }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Steps (one per line)").font(BK.Font.bodyMedium)
                        BKTextEditor(text: $steps, height: 110)
                    }
                    BKFormRow(title: "Done when") { BKTextField(placeholder: "The note shows the title", text: $skill.verification).frame(width: 300) }
                    BKFormRow(title: "Always ask for approval") { BKSwitch(isOn: $skill.requiresApproval, label: "Always ask for approval") }
                }
                HStack {
                    Button("Delete", role: .destructive, action: onDelete).buttonStyle(BKButtonStyle(kind: .ghost))
                    Spacer()
                    Button("Cancel", action: onCancel).buttonStyle(BKButtonStyle(kind: .secondary))
                    Button("Save") {
                        func list(_ s: String) -> [String] { s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                        skill.triggers = list(triggers)
                        skill.parameters = list(params)
                        skill.apps = list(apps)
                        skill.steps = steps.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        onSave(skill)
                    }
                    .buttonStyle(BKButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(22).frame(width: 600)
            .background(t.canvas)
        }
        .onAppear {
            triggers = skill.triggers.joined(separator: ", ")
            params = skill.parameters.joined(separator: ", ")
            apps = skill.apps.joined(separator: ", ")
            steps = skill.steps.joined(separator: "\n")
        }
    }
}

// MARK: - History

struct HistorySettingsView: View {
    @Bindable var store: SettingsStore
    @State private var tasks: [TaskRecord] = []
    @State private var selected: TaskRecord?
    @State private var events: [ActivityEntry] = []
    @State private var confirmClear = false

    var body: some View {
        BKSectionHeader(title: "History", subtitle: "What Glide did, step by step. Stored only on this Mac. Screenshots are never kept.")
        BKGroup {
            BKFormRow(title: "Keep task history") { BKSwitch(isOn: $store.settings.keepHistory, label: "Keep task history") }
            BKFormRow(title: "Clear history", detail: "Deletes every task record and log from this Mac.") {
                Button("Clear…") { confirmClear = true }.buttonStyle(BKButtonStyle(kind: .destructive, compact: true)).fixedSize()
            }
        }
        .confirmationDialog("Delete all task history?", isPresented: $confirmClear) {
            Button("Delete history", role: .destructive) { LocalStore.shared.clearHistory(); reload() }
        }
        BKGroupHeader(title: "Recent tasks")
        if tasks.isEmpty {
            BKEmptyState(icon: "clock", title: "No tasks yet", message: "Tasks you run from the notch show up here.")
        }
        ForEach(tasks) { t in
            BKCard(padding: 12, selected: selected?.id == t.id) {
                HStack(alignment: .top, spacing: 10) {
                    BKStatusDot(tone: tone(t)).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(t.instruction).font(BK.Font.bodyMedium).lineLimit(2)
                        HStack(spacing: 6) {
                            BKBadge(text: t.status.capitalized, tone: tone(t))
                            Text(subtitle(t)).font(BK.Font.caption).foregroundStyle(.secondary)
                        }
                        if let s = t.summary ?? t.error { Text(s).font(BK.Font.caption).foregroundStyle(.secondary).lineLimit(2) }
                    }
                    Spacer()
                    if t.status == "completed", let plan = t.plan {
                        Button("Save as skill") { LocalStore.shared.saveSkill(Skill.from(plan: plan, instruction: t.instruction)) }
                            .buttonStyle(BKButtonStyle(kind: .ghost, compact: true)).fixedSize()
                    }
                    Button(selected?.id == t.id ? "Hide" : "Details") {
                        withAnimation(.snappy(duration: 0.25)) {
                            if selected?.id == t.id { selected = nil } else { selected = t; events = LocalStore.shared.events(taskID: t.id) }
                        }
                    }.buttonStyle(BKButtonStyle(kind: .secondary, compact: true)).fixedSize()
                }
                if selected?.id == t.id {
                    if let m = t.metrics {
                        HStack(spacing: 6) {
                            BKBadge(text: "\(m.actions) actions")
                            BKBadge(text: "\(m.modelCalls) model calls")
                            if m.visionCalls > 0 { BKBadge(text: "\(m.visionCalls) vision", tone: .info) }
                            if m.recoveries > 0 { BKBadge(text: "\(m.recoveries) recoveries", tone: .warning) }
                            BKBadge(text: "\(m.inputTokens + m.outputTokens) tokens")
                            if let c = m.estimatedCost { BKBadge(text: String(format: "~$%.4f", c)) }
                        }
                    }
                    BKTimeline(entries: events, onDark: false)
                }
            }
        }
        Color.clear.frame(height: 0).onAppear(perform: reload)
    }

    func tone(_ t: TaskRecord) -> BK.Tone {
        switch t.status {
        case "completed": return .success
        case "running": return .info
        case "stopped": return .neutral
        case "needsInput": return .warning
        default: return .danger
        }
    }

    func subtitle(_ t: TaskRecord) -> String {
        let df = RelativeDateTimeFormatter()
        var s = df.localizedString(for: t.startedAt, relativeTo: Date())
        if let d = t.durationMs { s += " · \(String(format: "%.1fs", d / 1000))" }
        return s
    }

    func reload() { tasks = LocalStore.shared.recentTasks(limit: 100) }
}
