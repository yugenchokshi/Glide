import Foundation
import AutomationKit

/// Which browser tab each job item, job or quick task is working in, which tabs Glide opened,
/// and the latest snapshot of every tab the tools have looked at.
///
/// Each key (see `key(jobID:itemID:)`) has one "current tab", so parallel job items never step
/// on each other's pages, and a quick task keeps working in the tab it opened. Tabs Glide opens
/// are recycled least-recently-used beyond a per-job cap, so a job over 500 items doesn't leave
/// 500 tabs behind; tabs the user opened are never closed by this.
///
/// Tools read this synchronously inside `assess` — risk is judged from the element the model
/// actually saw, without I/O — so it's a lock-protected class rather than an actor. Async work
/// (closing tabs) never runs while the lock is held.
public final class BrowserSessions: @unchecked Sendable {
    public static let shared = BrowserSessions()

    struct Session: Sendable {
        var backend: BrowserBackendKind
        var tabID: String
        var jobID: String?
    }

    struct GlideTab: Sendable {
        var backend: BrowserBackendKind
        var tabID: String
        var jobID: String?
        var lastUsed: Date
    }

    /// Glide-opened tabs kept per job (quick tasks share one group); older ones get closed.
    public let maxTabsPerJob: Int
    /// Glide-opened tabs kept overall.
    public let maxTabs: Int

    private let lock = NSLock()
    private var sessions: [String: Session] = [:]
    private var glideTabs: [String: GlideTab] = [:]
    private var snapshots: [String: PageSnapshot] = [:]
    private var drivers: [BrowserDriver] = []

    public init(maxTabsPerJob: Int = 4, maxTabs: Int = 12) {
        self.maxTabsPerJob = max(1, maxTabsPerJob)
        self.maxTabs = max(self.maxTabsPerJob, maxTabs)
    }

    /// Session key: one tab per job item, else per job, else one shared by quick tasks.
    public static func key(jobID: String?, itemID: String?) -> String {
        switch (jobID, itemID) {
        case let (j?, i?): return "job:\(j)/item:\(i)"
        case let (j?, nil): return "job:\(j)"
        case let (nil, i?): return "item:\(i)"
        case (nil, nil): return "default"
        }
    }

    static func tabKey(_ kind: BrowserBackendKind, _ tabID: String) -> String { "\(kind.rawValue)|\(tabID)" }

    /// One driver per backend, so ref counters survive across tool calls.
    func driver(for backend: any BrowserBackend) -> BrowserDriver {
        lock.withLock {
            if let d = drivers.first(where: { $0.backend === backend }) { return d }
            let d = BrowserDriver(backend: backend)
            drivers.append(d)
            return d
        }
    }

    func session(_ key: String) -> Session? { lock.withLock { sessions[key] } }

    /// Marks the key's current tab as just used (it's then the last to be recycled).
    func touch(_ key: String) {
        lock.withLock {
            guard let s = sessions[key] else { return }
            glideTabs[Self.tabKey(s.backend, s.tabID)]?.lastUsed = Date()
        }
    }

    /// Makes `tabID` the key's current tab. `openedByGlide` records it as Glide's (for closing and
    /// risk). Returns the Glide tabs to close to stay under the caps; the caller closes them
    /// outside the lock.
    @discardableResult
    func adopt(key: String, backend: BrowserBackendKind, tabID: String, jobID: String?, openedByGlide: Bool) -> [GlideTab] {
        lock.withLock {
            sessions[key] = Session(backend: backend, tabID: tabID, jobID: jobID)
            let k = Self.tabKey(backend, tabID)
            if openedByGlide, glideTabs[k] == nil {
                glideTabs[k] = GlideTab(backend: backend, tabID: tabID, jobID: jobID, lastUsed: Date())
            }
            glideTabs[k]?.lastUsed = Date()
            var victims: [GlideTab] = []
            func evict(where include: (GlideTab) -> Bool, cap: Int) {
                while glideTabs.values.filter(include).count > cap {
                    guard let oldest = glideTabs.filter({ include($0.value) && $0.key != k }).min(by: { $0.value.lastUsed < $1.value.lastUsed }) else { return }
                    glideTabs[oldest.key] = nil
                    snapshots[oldest.key] = nil
                    // Whoever still pointed at it (a finished item, most likely) opens a new tab next time.
                    for (sk, s) in sessions where Self.tabKey(s.backend, s.tabID) == oldest.key { sessions[sk] = nil }
                    victims.append(oldest.value)
                }
            }
            evict(where: { $0.jobID == jobID }, cap: maxTabsPerJob)
            evict(where: { _ in true }, cap: maxTabs)
            return victims
        }
    }

    func clear(_ key: String) { lock.withLock { _ = sessions.removeValue(forKey: key) } }

    /// Forgets a closed tab everywhere.
    func forgetTab(backend: BrowserBackendKind, tabID: String) {
        let k = Self.tabKey(backend, tabID)
        let ds: [BrowserDriver] = lock.withLock {
            snapshots[k] = nil
            glideTabs[k] = nil
            for (key, s) in sessions where s.backend == backend && s.tabID == tabID { sessions[key] = nil }
            return drivers
        }
        for d in ds where d.backend.kind == backend { d.forget(tabID: tabID) }
    }

    /// Records a tab Glide caused to open (a popup from a click) as Glide's.
    func markGlideTab(backend: BrowserBackendKind, tabID: String, jobID: String?) {
        lock.withLock {
            let k = Self.tabKey(backend, tabID)
            if glideTabs[k] == nil { glideTabs[k] = GlideTab(backend: backend, tabID: tabID, jobID: jobID, lastUsed: Date()) }
        }
    }

    func isGlideTab(backend: BrowserBackendKind, tabID: String) -> Bool {
        lock.withLock { glideTabs[Self.tabKey(backend, tabID)] != nil }
    }

    /// Snapshots kept at most; tabs closed outside Glide never report it, so the oldest go.
    static let maxSnapshots = 64

    func record(_ snapshot: PageSnapshot, backend: BrowserBackendKind) {
        lock.withLock {
            let k = Self.tabKey(backend, snapshot.tabID)
            snapshots[k] = snapshot
            if snapshots.count > Self.maxSnapshots, let oldest = snapshots.min(by: { $0.value.timestamp < $1.value.timestamp })?.key, oldest != k {
                snapshots[oldest] = nil
            }
        }
    }

    func lastSnapshot(backend: BrowserBackendKind, tabID: String) -> PageSnapshot? {
        lock.withLock { snapshots[Self.tabKey(backend, tabID)] }
    }

    /// The latest snapshot of the key's current tab (what `assess` judges against).
    func currentSnapshot(_ key: String) -> PageSnapshot? {
        lock.withLock {
            guard let s = sessions[key] else { return nil }
            return snapshots[Self.tabKey(s.backend, s.tabID)]
        }
    }

    /// Opens a tab for `key` (in the background unless told otherwise) and makes it current,
    /// closing Glide tabs beyond the caps.
    func openTab(key: String, jobID: String?, url: String, background: Bool, driver: BrowserDriver) async throws -> String {
        let tab = try await driver.openTab(url: url, background: background)
        let victims = adopt(key: key, backend: driver.backend.kind, tabID: tab.id, jobID: jobID, openedByGlide: true)
        await close(victims, driver: driver)
        return tab.id
    }

    /// Closes the tab of one job item (or of the job itself when `itemID` is nil) if Glide
    /// opened it. The job engine can call this when an item finishes to free the tab early;
    /// otherwise tabs are recycled least-recently-used.
    public func release(jobID: String?, itemID: String?, hub: BrowserHub = .shared) async {
        let key = Self.key(jobID: jobID, itemID: itemID)
        let victim: GlideTab? = lock.withLock {
            guard let s = sessions.removeValue(forKey: key) else { return nil }
            let k = Self.tabKey(s.backend, s.tabID)
            guard let g = glideTabs[k], !sessions.values.contains(where: { Self.tabKey($0.backend, $0.tabID) == k }) else { return nil }
            glideTabs[k] = nil
            return g
        }
        guard let victim, let backend = hub.registered(victim.backend) else { return }
        await close([victim], driver: driver(for: backend))
    }

    /// Closes every tab a job opened (call when the job ends).
    public func releaseJob(_ jobID: String, hub: BrowserHub = .shared) async {
        let victims: [GlideTab] = lock.withLock {
            for (k, s) in sessions where s.jobID == jobID { sessions[k] = nil }
            let mine = glideTabs.filter { $0.value.jobID == jobID }
            for k in mine.keys { glideTabs[k] = nil }
            return Array(mine.values)
        }
        for v in victims {
            guard let backend = hub.registered(v.backend) else { continue }
            await close([v], driver: driver(for: backend))
        }
    }

    private func close(_ victims: [GlideTab], driver: BrowserDriver) async {
        for v in victims where v.backend == driver.backend.kind {
            try? await driver.closeTab(v.tabID)
            forgetTab(backend: v.backend, tabID: v.tabID)
        }
    }
}
