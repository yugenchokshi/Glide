import Foundation

/// Pairing details for the Glide Chrome extension (shown in Settings › Browser).
public struct BrowserPairingInfo: Sendable, Hashable {
    /// Secret the extension presents when it connects.
    public var token: String
    public var port: Int
    /// Folder to "Load unpacked" in chrome://extensions.
    public var extensionFolder: URL?
    /// Stable id of the unpacked extension (derived from its manifest key).
    public var extensionID: String
    /// URL that pairs automatically when opened in Chrome with the extension installed.
    public var pairingURL: URL?

    public init(token: String, port: Int, extensionFolder: URL?, extensionID: String, pairingURL: URL?) {
        self.token = token
        self.port = port
        self.extensionFolder = extensionFolder
        self.extensionID = extensionID
        self.pairingURL = pairingURL
    }
}

/// Chooses the browser backend for each task and reports connection status.
///
/// CONTRACT: backends register themselves at launch (`register`). The extension bridge and
/// Glide's own Chrome both conform to `BrowserBackend`; `BrowserDriver` (snapshots, clicks,
/// typing) runs on whichever `backend(for:)` returns.
public final class BrowserHub: @unchecked Sendable {
    public static let shared = BrowserHub()

    private let lock = NSLock()
    private var backends: [BrowserBackendKind: any BrowserBackend] = [:]

    /// Installed by the extension bridge: current pairing details.
    nonisolated(unsafe) public var pairingProvider: (@Sendable () -> BrowserPairingInfo?)?
    /// Installed by the extension bridge: forget the paired extension and mint a new token.
    nonisolated(unsafe) public var resetPairing: (@Sendable () -> Void)?
    /// Installed by the extension bridge: whether an extension has ever paired.
    nonisolated(unsafe) public var isExtensionPaired: (@Sendable () -> Bool)?

    public init() {}

    public func register(_ backend: any BrowserBackend) {
        lock.withLock { backends[backend.kind] = backend }
    }

    public func registered(_ kind: BrowserBackendKind) -> (any BrowserBackend)? {
        lock.withLock { backends[kind] }
    }

    /// The backend to use now: the preferred one if connected, else Glide's Chrome when
    /// fallback is allowed (connecting it on demand).
    public func backend(for settings: BrowserSettings) async throws -> any BrowserBackend {
        if let preferred = registered(settings.backend) {
            if await preferred.isConnected() { return preferred }
            if settings.backend == .glideChrome {
                try await preferred.connect()
                return preferred
            }
        }
        if settings.backend == .extensionBridge, settings.fallbackToGlideChrome, let fallback = registered(.glideChrome) {
            if !(await fallback.isConnected()) { try await fallback.connect() }
            return fallback
        }
        throw BrowserError.notConnected(settings.backend == .extensionBridge
            ? "The Glide Chrome extension isn't connected. Install it from Settings › Browser, or allow Glide's own Chrome window."
            : "Glide's Chrome window isn't available.")
    }

    public func status(settings: BrowserSettings) async -> BrowserStatus {
        let installed = ChromeLocator.executable(override: settings.chromePath) != nil
        guard let b = registered(settings.backend) else {
            return BrowserStatus(backend: settings.backend, connected: false, detail: "Not set up", chromeInstalled: installed, extensionPaired: false)
        }
        let connected = await b.isConnected()
        return BrowserStatus(backend: settings.backend, connected: connected,
                             detail: connected ? "Connected" : "Not connected", chromeInstalled: installed,
                             extensionPaired: isExtensionPaired?() ?? false)
    }
}
