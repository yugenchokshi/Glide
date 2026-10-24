import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AgentKit
import AutomationKit

/// Fixed status and pairing details for the snapshot renderer (no bridge, no Chrome).
struct BrowserSettingsPreview {
    var status: BrowserStatus
    var pairing: BrowserPairingInfo?
}

/// Settings › Browser: which Chrome Glide drives, its live connection status, and the
/// one-time setup of the Glide extension for your everyday Chrome.
struct BrowserSettingsView: View {
    @Bindable var store: SettingsStore
    var preview: BrowserSettingsPreview? = nil
    @State private var status: BrowserStatus?
    @State private var pairing: BrowserPairingInfo?
    @State private var paired = false
    @State private var copiedExtensionsURL = false
    @State private var pairNote: String?
    @State private var confirmReset = false
    /// The bridge port being edited; applied with the Apply button so a half-typed number
    /// doesn't restart the bridge on every keystroke.
    @State private var portText = ""

    static let extensionsPage = "chrome://extensions"

    var body: some View {
        let backend = store.settings.browser.backend
        BKSectionHeader(title: "Browser",
                        subtitle: "Glide controls Chrome directly — reading pages and clicking or typing by element, in background tabs — instead of moving your cursor over the page.")
        BKGroup {
            BKFormRow(title: "Use", detail: backendDetail(backend)) {
                BKSegmented(options: [(BrowserBackendKind.extensionBridge, "Your Chrome"), (.glideChrome, "Glide's Chrome")],
                            selection: $store.settings.browser.backend)
            }
            BKFormRow(title: "Status", detail: statusDetail(backend)) { statusBadge(backend) }
        }
        if let status, !status.chromeInstalled {
            BKCallout(tone: .warning, icon: "exclamationmark.triangle.fill", title: "Google Chrome isn't installed",
                      message: "Install Google Chrome, or point Glide at another Chromium-based browser under Custom Chrome below.")
        }

        if backend == .extensionBridge { extensionSetup }

        BKGroupHeader(title: "Options")
        BKGroup {
            BKFormRow(title: "Work in background tabs", detail: "Open pages in tabs behind the one you're using, so Chrome doesn't jump to the front while a job runs.") {
                BKSwitch(isOn: $store.settings.browser.useBackgroundTabs, label: "Work in background tabs")
            }
            if backend == .extensionBridge {
                BKFormRow(title: "Fall back to Glide's Chrome", detail: "When the extension isn't connected, use a separate Chrome window with its own profile (you'd need to sign in to sites there).") {
                    BKSwitch(isOn: $store.settings.browser.fallbackToGlideChrome, label: "Fall back to Glide's Chrome")
                }
            }
            if backend == .extensionBridge {
                BKFormRow(title: "Bridge port", detail: "The local port the extension connects to. Change it only if another app uses it, then pair the extension again.") {
                    HStack(spacing: 6) {
                        BKTextField(placeholder: String(BrowserSettings().bridgePort), text: $portText, monospaced: true).frame(width: 80)
                        Button("Apply", action: applyPort).buttonStyle(BKButtonStyle(kind: .secondary, compact: true)).fixedSize()
                            .disabled(newPort == nil)
                    }
                    .onAppear { portText = String(store.settings.browser.bridgePort) }
                }
            }
            BKFormRow(title: "Custom Chrome", detail: chromePathDetail) {
                HStack(spacing: 6) {
                    BKTextField(placeholder: "Default: Google Chrome", text: chromePath).frame(width: 220)
                    Button("Choose…", action: chooseChrome).buttonStyle(BKButtonStyle(kind: .secondary, compact: true)).fixedSize()
                }
            }
        }
        Color.clear.frame(height: 0)
            // Live status while this page is visible; `.task` stops when it disappears.
            .task(id: store.settings.browser) { await pollStatus() }
            .confirmationDialog("Reset pairing?", isPresented: $confirmReset) {
                Button("Reset pairing", role: .destructive) {
                    BrowserHub.shared.resetPairing?()
                    pairing = BrowserHub.shared.pairingProvider?()
                    paired = BrowserHub.shared.isExtensionPaired?() ?? false
                    pairNote = "Pairing reset. Pair the extension again to reconnect."
                }
            } message: {
                Text("The extension disconnects and the old pairing code stops working.")
            }
    }

    // MARK: Extension setup

    @ViewBuilder var extensionSetup: some View {
        BKGroupHeader(title: "Set up the Glide extension",
                      subtitle: "One-time setup. The extension lets Glide work in your own Chrome, with the sites you're already signed in to.")
        BKGroup {
            SetupStepRow(number: 1, title: "Reveal the extension folder",
                         detail: pairing?.extensionFolder?.path ?? "Available once Glide's browser bridge is running.") {
                Button("Reveal in Finder", action: revealExtension)
                    .buttonStyle(BKButtonStyle(kind: .secondary, compact: true)).fixedSize()
                    .disabled(pairing?.extensionFolder == nil)
            }
            SetupStepRow(number: 2, title: "Open Chrome's Extensions page",
                         detail: copiedExtensionsURL ? "Copied. Paste it into Chrome's address bar and press Return."
                                                     : "Chrome doesn't let other apps open chrome:// pages, so copy the address and paste it into Chrome's address bar.") {
                Button(copiedExtensionsURL ? "Copied" : "Copy \(Self.extensionsPage)") {
                    copy(Self.extensionsPage)
                    copiedExtensionsURL = true
                }
                .buttonStyle(BKButtonStyle(kind: .secondary, compact: true)).fixedSize()
            }
            SetupStepRow(number: 3, title: "Load the extension",
                         detail: "Turn on Developer mode (top right), click Load unpacked, and choose the folder from step 1.")
            SetupStepRow(number: 4, title: "Pair with Glide", detail: pairNote ?? pairDetail) {
                HStack(spacing: 6) {
                    Button("Copy pairing code", action: copyPairingCode)
                        .buttonStyle(BKButtonStyle(kind: .ghost, compact: true)).fixedSize()
                        .disabled(pairing == nil)
                        .help("Paste this into the Glide extension's popup if the pairing page doesn't open.")
                    Button("Pair", action: pair)
                        .buttonStyle(BKButtonStyle(kind: paired ? .secondary : .primary, compact: true)).fixedSize()
                        .disabled(pairing?.pairingURL == nil)
                }
            }
        }
        BKGroup {
            BKFormRow(title: "Reset pairing", detail: "Disconnects the extension and makes a new pairing code. Pair again afterwards.") {
                Button("Reset…") { confirmReset = true }
                    .buttonStyle(BKButtonStyle(kind: .destructive, compact: true)).fixedSize()
                    .disabled(BrowserHub.shared.resetPairing == nil && preview == nil)
            }
        }
    }

    var pairDetail: String {
        if paired { return "Paired with this Mac. Pair again after reinstalling the extension." }
        if pairing == nil { return "Available once Glide's browser bridge is running." }
        return "Opens a page in Chrome where you confirm the connection. Or copy the code and paste it into the extension's popup."
    }

    // MARK: Status

    func backendDetail(_ backend: BrowserBackendKind) -> String {
        switch backend {
        case .extensionBridge: return "Work in the Chrome you already use, through the Glide extension. Your logins and cookies just work."
        case .glideChrome: return "Glide opens its own Chrome window with a separate profile. Nothing to install, but you sign in to sites there."
        }
    }

    func statusDetail(_ backend: BrowserBackendKind) -> String {
        guard let status else { return "Checking…" }
        if status.connected { return status.detail }
        switch backend {
        case .extensionBridge:
            if !status.extensionPaired && !paired { return "The extension isn't set up yet. Follow the steps below." }
            return "Chrome isn't connected. Open Chrome; the extension reconnects within a few seconds."
        case .glideChrome:
            return status.chromeInstalled ? "Starts automatically when a task needs the browser." : status.detail
        }
    }

    @ViewBuilder func statusBadge(_ backend: BrowserBackendKind) -> some View {
        if let status {
            if status.connected {
                BKBadge(text: "Connected", tone: .success, icon: "checkmark")
            } else if backend == .extensionBridge && !(status.extensionPaired || paired) {
                BKBadge(text: "Not set up", tone: .warning)
            } else if backend == .glideChrome && status.chromeInstalled {
                BKBadge(text: "Ready", tone: .neutral)
            } else {
                BKBadge(text: "Not connected", tone: .neutral)
            }
        } else {
            BKProgressRing(size: 12, trackColor: BK.Palette.n300)
        }
    }

    func pollStatus() async {
        if let preview {
            status = preview.status
            pairing = preview.pairing
            paired = preview.status.extensionPaired
            return
        }
        while !Task.isCancelled {
            let settings = store.settings.browser
            let s = await BrowserHub.shared.status(settings: settings)
            guard !Task.isCancelled else { return }
            status = s
            pairing = BrowserHub.shared.pairingProvider?()
            paired = BrowserHub.shared.isExtensionPaired?() ?? s.extensionPaired
            try? await Task.sleep(for: .seconds(2))
        }
    }

    // MARK: Actions

    func revealExtension() {
        guard let folder = pairing?.extensionFolder else { return }
        if FileManager.default.fileExists(atPath: folder.path) {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } else {
            pairNote = "The extension folder is missing at \(folder.path). Reinstall Glide to restore it."
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// A valid port that differs from the current one, or nil.
    var newPort: Int? {
        guard let p = Int(portText.trimmingCharacters(in: .whitespaces)), (1024...65535).contains(p),
              p != store.settings.browser.bridgePort else { return nil }
        return p
    }

    /// Glide restarts the bridge on the new port by itself (AppDelegate watches the setting);
    /// the pairing code includes the port, so the extension has to pair again.
    func applyPort() {
        guard let p = newPort else { return }
        store.settings.browser.bridgePort = p
        pairNote = "Glide now listens on port \(p). Pair the extension again so it uses the new port."
    }

    func copyPairingCode() {
        guard let pairing else { return }
        copy("\(pairing.port):\(pairing.token)")
        pairNote = "Pairing code copied. Click the Glide extension's icon in Chrome and paste it there."
    }

    /// Opens the pairing page in Chrome specifically (it's a chrome-extension:// URL that no
    /// other browser can open).
    func pair() {
        guard let url = pairing?.pairingURL else { return }
        guard let chrome = Self.chromeAppURL(settings: store.settings.browser) else {
            pairNote = "Couldn't find Chrome. Copy the pairing code and paste it into the extension's popup instead."
            return
        }
        Task {
            do {
                _ = try await NSWorkspace.shared.open([url], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
                pairNote = "Pairing page opened in Chrome. Click Pair there to finish."
            } catch {
                pairNote = "Couldn't open Chrome (\(error.localizedDescription)). Copy the pairing code and paste it into the extension's popup."
            }
        }
    }

    /// The Chrome app bundle: the custom path's app if set, else the installed Google Chrome.
    static func chromeAppURL(settings: BrowserSettings) -> URL? {
        if let exe = ChromeLocator.executable(override: settings.chromePath) {
            // …/Google Chrome.app/Contents/MacOS/Google Chrome → …/Google Chrome.app
            let app = URL(fileURLWithPath: exe).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            if app.pathExtension == "app" { return app }
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome")
    }

    var chromePath: Binding<String> {
        Binding(get: { store.settings.browser.chromePath ?? "" },
                set: {
                    let v = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.settings.browser.chromePath = v.isEmpty ? nil : v
                })
    }

    var chromePathDetail: String {
        guard let path = store.settings.browser.chromePath else { return "Another Chromium-based browser to use instead of Google Chrome." }
        return FileManager.default.isExecutableFile(atPath: path)
            ? "Using \(URL(fileURLWithPath: path).lastPathComponent)."
            : "That path isn't a program Glide can run, so it uses Google Chrome. Choose the app itself."
    }

    func chooseChrome() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            // An .app bundle → the executable inside it, which is what ChromeLocator runs.
            let exe = url.pathExtension == "app" ? Bundle(url: url)?.executableURL?.path : url.path
            MainActor.assumeIsolated {
                if let exe {
                    store.settings.browser.chromePath = exe
                } else {
                    pairNote = "\(url.lastPathComponent) doesn't look like an app Glide can launch."
                }
            }
        }
    }
}

/// Numbered setup step: a step badge, title and detail, and an optional control.
private struct SetupStepRow<Accessory: View>: View {
    let number: Int
    let title: String
    var detail: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        BKThemeReader { t in
            HStack(alignment: .center, spacing: 11) {
                Text("\(number)").font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundStyle(t.accentText)
                    .frame(width: 22, height: 22).background(Circle().fill(t.accentSoft))
                BKFormRow(title: title, detail: detail) { accessory }
            }
        }
    }
}

extension SetupStepRow where Accessory == EmptyView {
    init(number: Int, title: String, detail: String? = nil) {
        self.init(number: number, title: title, detail: detail) { EmptyView() }
    }
}
