import Foundation

// App-side wiring for the Chrome extension bridge. The bridge itself lives in AutomationKit,
// which can't see AgentKit's settings, Keychain store or BrowserHub, so this extension connects
// them: `ExtensionBridge.shared.start(settings:)` is the one call made at launch.

/// Keeps the bridge's pairing token in the Keychain next to the app's other credentials.
struct KeychainExtensionBridgeStore: ExtensionBridgeStore {
    static let tokenKey = CredentialStore.Key.custom("browser.bridge-token")
    /// "1" once an extension has completed pairing with the current token.
    static let pairedKey = CredentialStore.Key.custom("browser.bridge-paired")

    let credentials: CredentialStore

    func loadToken() -> String? { credentials.get(Self.tokenKey) }
    func saveToken(_ token: String) -> Bool { credentials.set(token, for: Self.tokenKey) }
    func loadPaired() -> Bool { credentials.get(Self.pairedKey) == "1" }

    func savePaired(_ paired: Bool) {
        if paired { credentials.set("1", for: Self.pairedKey) } else { credentials.remove(Self.pairedKey) }
    }
}

extension ExtensionBridge {
    /// Starts the bridge on `settings.bridgePort` with the Keychain-backed token (minted on first
    /// launch), registers an `ExtensionBackend` with the hub and installs the hub's pairing
    /// hooks. Safe to call again when the port setting changes.
    public func start(settings: BrowserSettings, credentials: CredentialStore = .shared, hub: BrowserHub = .shared) {
        start(port: settings.bridgePort, store: KeychainExtensionBridgeStore(credentials: credentials))
        if (hub.registered(.extensionBridge) as? ExtensionBackend)?.bridge !== self {
            hub.register(ExtensionBackend(bridge: self))
        }
        hub.pairingProvider = { [self] in
            guard let pairing = pairing() else { return nil }
            return BrowserPairingInfo(token: pairing.token, port: pairing.port, extensionFolder: pairing.extensionFolder,
                                      extensionID: pairing.extensionID, pairingURL: pairing.pairingURL)
        }
        hub.resetPairing = { [self] in resetPairing() }
        hub.isExtensionPaired = { [self] in isPaired }
    }
}
