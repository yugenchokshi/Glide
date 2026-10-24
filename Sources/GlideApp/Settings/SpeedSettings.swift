import SwiftUI
import AgentKit

/// Settings › Speed & Commands: how much Glide does directly (commands, scripts, files)
/// instead of clicking through apps, and what it may run without asking.
struct SpeedSettingsView: View {
    @Bindable var store: SettingsStore

    var body: some View {
        BKSectionHeader(title: "Speed & Commands",
                        subtitle: "Glide is fastest when it works directly — running commands, scripts and file operations, and controlling Chrome tabs — and only moves your cursor for steps that need an app's interface.")
        BKGroupHeader(title: "How Glide works")
        BKGroup {
            BKFormRow(title: "Execution", detail: executionDetail) {
                BKSegmented(options: ExecutionPreference.allCases.map { ($0, $0.title) }, selection: $store.settings.tools.executionPreference)
            }
            BKFormRow(title: "Batch actions", detail: "Let the model plan several actions in one go (fill a whole form, then submit) instead of one per call. Fewer model calls, much faster.") {
                BKSwitch(isOn: $store.settings.tools.batchActions, label: "Batch actions")
            }
            BKFormRow(title: "Actions per batch", detail: "A batch stops early at the first error or unexpected change on screen.") {
                BKStepper(value: $store.settings.tools.maxBatch, range: 2...10)
            }
            .disabled(!store.settings.tools.batchActions)
        }

        BKGroupHeader(title: "Commands and scripts", subtitle: "Shell commands, AppleScript, Shortcuts and file operations run in the background without touching the screen.")
        BKGroup {
            BKFormRow(title: "Command access", detail: accessDetail) {
                BKSegmented(options: [(CommandAccess.off, "Off"), (.readOnly, "Read-only"), (.full, "Full")], selection: $store.settings.tools.commandAccess)
            }
            BKFormRow(title: "AppleScript and JavaScript for Automation", detail: "Script apps directly (read a Mail mailbox, make a Numbers table). Scripts that send, delete or run shell commands still ask first.") {
                BKSwitch(isOn: $store.settings.tools.allowAppleScript, label: "AppleScript")
            }
            .disabled(store.settings.tools.commandAccess == .off)
            BKFormRow(title: "Shortcuts", detail: "Run your Shortcuts by name, with input.") {
                BKSwitch(isOn: $store.settings.tools.allowShortcuts, label: "Shortcuts")
            }
            .disabled(store.settings.tools.commandAccess == .off)
        }

        BKGroupHeader(title: "What runs on its own", subtitle: "Risk is decided by fixed rules, before anything runs — never by the AI model.")
        BKGroup {
            SafetyTierRow(tone: .success, icon: "checkmark.shield.fill", title: "Runs automatically",
                          detail: "Anything that only reads: listing and reading files, Spotlight search, git status and log, fetching web pages, system info.")
            SafetyTierRow(tone: .warning, icon: "hand.raised.fill", title: "Asks you first",
                          detail: "Deleting or overwriting files, sending or uploading, git push, quitting processes, and writing outside your home folder. Smaller changes like creating files follow “Ask before” in Safety.")
            SafetyTierRow(tone: .danger, icon: "nosign", title: "Always blocked",
                          detail: "sudo, erasing disks, turning off system security, deleting your home folder or Keychains, and piping downloads straight into a shell.")
        }
    }

    var executionDetail: String {
        switch store.settings.tools.executionPreference {
        case .fastest: return "Use commands, files, background browser tabs and web fetches wherever possible. Steps finish in seconds and your screen stays yours."
        case .showMe: return "Prefer working in apps on screen, so you can watch every step. Slower, and it uses your cursor."
        }
    }

    var accessDetail: String {
        switch store.settings.tools.commandAccess {
        case .off: return "Glide never runs commands or scripts; it uses apps on screen instead."
        case .readOnly: return "Only commands that can't change anything (ls, cat, mdfind, git status…). Everything else is refused."
        case .full: return "Any command. Changes follow your approval settings, and dangerous ones are always blocked."
        }
    }
}

private struct SafetyTierRow: View {
    let tone: BK.Tone
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        BKThemeReader { t in
            let chip = tone.chip(dark: t.dark)
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(chip.text)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(chip.background))
                BKFormRow(title: title, detail: detail)
            }
        }
    }
}
