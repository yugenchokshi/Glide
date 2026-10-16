import SwiftUI
import AppKit
import AgentKit
import AutomationKit

// MARK: - Permissions

struct PermissionsSettingsView: View {
    @State private var statuses: [PermissionKind: PermissionStatus] = [:]
    let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        BKSectionHeader(title: "Permissions", subtitle: "macOS asks you to grant these. NotchBuddy can't grant them to itself.")
        BKCard {
            ForEach(PermissionKind.allCases) { kind in
                PermissionRow(kind: kind, status: statuses[kind] ?? .unknown) {
                    Task { statuses[kind] = await PermissionManager.request(kind) }
                }
                if kind != PermissionKind.allCases.last { Divider() }
            }
        }
        Text("After granting Accessibility or Screen Recording, macOS may require relaunching NotchBuddy.")
            .font(.system(size: 11.5)).foregroundStyle(.secondary)
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
        BKFormRow(title: kind.title, detail: kind.purpose) {
            HStack(spacing: 8) {
                switch status {
                case .granted: BKBadge(text: "Granted", tone: .success)
                case .denied: BKBadge(text: kind == .accessibility ? "Required" : "Not granted", tone: kind == .accessibility ? .danger : .warning)
                case .notDetermined: BKBadge(text: "Not granted", tone: .warning)
                case .unknown: BKBadge(text: "Asked when needed", tone: .neutral)
                }
                if status != .granted {
                    Button(kind == .automation ? "Open Settings" : "Grant…", action: request)
                        .buttonStyle(BKButtonStyle(kind: kind == .accessibility ? .primary : .secondary, compact: true))
                }
            }
        }
    }
}

// MARK: - Safety

struct SafetySettingsView: View {
    @Bindable var store: SettingsStore
    @State private var newApp = ""

    var body: some View {
        BKSectionHeader(title: "Safety", subtitle: "High-risk actions (sending, deleting, publishing, purchasing, security changes) always wait for your approval. Password fields and card numbers are never typed.")
        BKCard {
            BKFormRow(title: "Ask before", detail: nil) {
                Picker("", selection: $store.settings.safety.approvalLevel) {
                    ForEach(ApprovalLevel.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 360)
            }
            Divider()
            BKFormRow(title: "Screenshots to vision models", detail: "Used only when a control isn't exposed to accessibility and local OCR can't find it. Password fields are blacked out first.") {
                Picker("", selection: $store.settings.safety.screenshotConsent) {
                    ForEach(ScreenshotConsent.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 200)
            }
            Divider()
            BKFormRow(title: "Pause when I move the mouse", detail: "Grabbing the mouse during a task pauses the agent instantly.") {
                Toggle("", isOn: $store.settings.safety.pauseOnUserInput).labelsHidden().toggleStyle(.switch)
            }
        }
        BKCard {
            Text("Excluded apps").font(.system(size: 13, weight: .semibold))
            Text("NotchBuddy will never read or operate these apps (names or bundle IDs).").font(.system(size: 11.5)).foregroundStyle(.secondary)
            ForEach(store.settings.safety.excludedApps, id: \.self) { app in
                HStack {
                    Image(systemName: "nosign").foregroundStyle(.secondary)
                    Text(app).font(.system(size: 12.5))
                    Spacer()
                    Button { store.settings.safety.excludedApps.removeAll { $0 == app } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                }
            }
            HStack {
                BKTextField(placeholder: "App name or bundle ID", text: $newApp).onSubmit(add)
                Button("Add", action: add).buttonStyle(BKButtonStyle(kind: .secondary, compact: true)).disabled(newApp.isEmpty)
            }
        }
        BKCard {
            Text("Limits").font(.system(size: 13, weight: .semibold))
            Stepper("Max steps per task: \(store.settings.limits.maxSteps)", value: $store.settings.limits.maxSteps, in: 3...60)
            Stepper("Max actions per step: \(store.settings.limits.maxActionsPerStep)", value: $store.settings.limits.maxActionsPerStep, in: 3...40)
            Stepper("Max actions per task: \(store.settings.limits.maxTotalActions)", value: $store.settings.limits.maxTotalActions, in: 10...300, step: 10)
            Stepper("Retries before giving up: \(store.settings.limits.retryLimit)", value: $store.settings.limits.retryLimit, in: 0...8)
            Stepper("Replans after failures: \(store.settings.limits.maxReplans)", value: $store.settings.limits.maxReplans, in: 0...5)
            Stepper("Task timeout: \(Int(store.settings.limits.taskTimeoutSeconds / 60)) min", value: $store.settings.limits.taskTimeoutSeconds, in: 60...3600, step: 60)
        }
    }

    func add() {
        let v = newApp.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, !store.settings.safety.excludedApps.contains(v) else { return }
        store.settings.safety.excludedApps.append(v)
        newApp = ""
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
        BKSectionHeader(title: "Shortcuts", subtitle: "Global shortcuts work from any app. The emergency stop works even when NotchBuddy's UI is hidden.")
        BKCard {
            row(.open, "Open NotchBuddy", \.open)
            Divider()
            row(.pauseResume, "Pause / resume", \.pauseResume)
            Divider()
            row(.stop, "Emergency stop", \.stop)
        }
        .onAppear { conflictText = conflicts() }
        .onDisappear(perform: endRecording)
    }

    @ViewBuilder func row(_ action: HotkeyManager.Action, _ title: String, _ path: WritableKeyPath<HotkeySettings, HotkeySetting>) -> some View {
        BKFormRow(title: title, detail: conflictText[action]) {
            HStack(spacing: 8) {
                if recording == action {
                    Text("Press keys…").font(.system(size: 12)).foregroundStyle(BK.Tone.accent.color)
                } else {
                    BKKeyCap(text: store.settings.hotkeys[keyPath: path].display)
                }
                Button(recording == action ? "Cancel" : "Change") {
                    if recording == action { endRecording() } else { beginRecording(action, path) }
                }.buttonStyle(BKButtonStyle(kind: .secondary, compact: true))
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
        HStack {
            Button { editing = Skill(name: "New skill", description: "", triggers: [], steps: []) } label: { Label("New skill", systemImage: "plus") }
                .buttonStyle(BKButtonStyle(kind: .secondary, compact: true))
            Spacer()
        }
        if skills.isEmpty {
            BKCard { Text("No skills yet. Save one from a completed task in History, or create one here.").font(.system(size: 12)).foregroundStyle(.secondary) }
        }
        ForEach(skills) { skill in
            BKCard {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(skill.name).font(.system(size: 13, weight: .semibold))
                        Text(skill.description).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    if skill.requiresApproval { BKBadge(text: "approval", tone: .warning) }
                    Button("Edit") { editing = skill }.buttonStyle(BKButtonStyle(kind: .ghost, compact: true))
                }
                Text(skill.steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
        EmptyView()
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
        VStack(alignment: .leading, spacing: 10) {
            Text("Skill").font(.system(size: 16, weight: .semibold))
            BKFormRow(title: "Name") { BKTextField(placeholder: "Meeting note", text: $skill.name).frame(width: 320) }
            BKFormRow(title: "Description") { BKTextField(placeholder: "What it does", text: $skill.description).frame(width: 320) }
            BKFormRow(title: "Triggers", detail: "Comma-separated phrases") { BKTextField(placeholder: "meeting note, standup notes", text: $triggers).frame(width: 320) }
            BKFormRow(title: "Parameters", detail: "Comma-separated") { BKTextField(placeholder: "topic, attendees", text: $params).frame(width: 320) }
            BKFormRow(title: "Preconditions") { BKTextField(placeholder: "Notes is installed", text: $skill.preconditions).frame(width: 320) }
            BKFormRow(title: "Apps") { BKTextField(placeholder: "Notes", text: $apps).frame(width: 320) }
            Text("Steps (one per line)").font(.system(size: 13, weight: .medium))
            TextEditor(text: $steps).font(.system(size: 12)).frame(height: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            BKFormRow(title: "Done when") { BKTextField(placeholder: "The note shows the title", text: $skill.verification).frame(width: 320) }
            Toggle("Always ask for approval", isOn: $skill.requiresApproval)
            HStack {
                Button("Delete", role: .destructive, action: onDelete)
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") {
                    func list(_ s: String) -> [String] { s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                    skill.triggers = list(triggers)
                    skill.parameters = list(params)
                    skill.apps = list(apps)
                    skill.steps = steps.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    onSave(skill)
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 580)
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
        BKSectionHeader(title: "History", subtitle: "What NotchBuddy did, step by step. Stored only on this Mac. Screenshots are never kept.")
        BKCard {
            BKFormRow(title: "Keep task history") { Toggle("", isOn: $store.settings.keepHistory).labelsHidden().toggleStyle(.switch) }
            Divider()
            BKFormRow(title: "Clear history", detail: "Deletes every task record and log from this Mac.") {
                Button("Clear…") { confirmClear = true }.buttonStyle(BKButtonStyle(kind: .destructive, compact: true))
            }
        }
        .confirmationDialog("Delete all task history?", isPresented: $confirmClear) {
            Button("Delete history", role: .destructive) { LocalStore.shared.clearHistory(); reload() }
        }
        ForEach(tasks) { t in
            BKCard(padding: 12) {
                HStack(alignment: .top) {
                    BKStatusDot(tone: t.status == "completed" ? .success : (t.status == "running" ? .info : (t.status == "stopped" ? .neutral : .danger)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(t.instruction).font(.system(size: 13, weight: .medium)).lineLimit(2)
                        Text(subtitle(t)).font(.system(size: 11)).foregroundStyle(.secondary)
                        if let s = t.summary ?? t.error { Text(s).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2) }
                    }
                    Spacer()
                    if t.status == "completed", let plan = t.plan {
                        Button("Save as skill") { LocalStore.shared.saveSkill(Skill.from(plan: plan, instruction: t.instruction)) }
                            .buttonStyle(BKButtonStyle(kind: .ghost, compact: true))
                    }
                    Button(selected?.id == t.id ? "Hide" : "Details") {
                        if selected?.id == t.id { selected = nil } else { selected = t; events = LocalStore.shared.events(taskID: t.id) }
                    }.buttonStyle(BKButtonStyle(kind: .secondary, compact: true))
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
        EmptyView().onAppear(perform: reload)
    }

    func subtitle(_ t: TaskRecord) -> String {
        let df = RelativeDateTimeFormatter()
        var s = "\(t.status.capitalized) · \(df.localizedString(for: t.startedAt, relativeTo: Date()))"
        if let d = t.durationMs { s += " · \(String(format: "%.1fs", d / 1000))" }
        return s
    }

    func reload() { tasks = LocalStore.shared.recentTasks(limit: 100) }
}
