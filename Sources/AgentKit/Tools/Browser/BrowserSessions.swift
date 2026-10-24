import Foundation
import AutomationKit

/// Which browser tab each job item, job or quick task is working in, which tabs Glide opened,
/// and the latest snapshot of every tab the tools have looked at.
///
/// Each key (see `key(jobID:itemID:)`) has one "current tab", so parallel job items never step
/// on each other's pages, and a quick task keeps working in the tab it opened. Tabs Glide opens
/// are recycled least-recently-used beyond a per-job cap, so a job over 500 items doesn't leave
/// 500 tabs behind; tabs the user opened are never closed by this, and neither is a tab that is
/// still some item's, job's or quick task's current tab (the cap is exceeded for a while instead).
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
        /// The session key that opened it, so `release` also closes the tabs an item left
        /// behind (the page before a popup, a `new_tab`), not just its current one.
        var owner: String?
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
    ///
    /// Only tabs nobody is working in are recycled: a tab that is another session's current tab
    /// (a parallel item thinking about its next step, a job's own tab, the quick task's) and the
    /// tab this key just moved away from are spared, even if that leaves the job over its cap
    /// until those sessions end.
    @discardableResult
    func adopt(key: String, backend: BrowserBackendKind, tabID: String, jobID: String?, openedByGlide: Bool) -> [GlideTab] {
        lock.withLock {
            let previous = sessions[key].map { Self.tabKey($0.backend, $0.tabID) }
            sessions[key] = Session(backend: backend, tabID: tabID, jobID: jobID)
            let k = Self.tabKey(backend, tabID)
            if openedByGlide, glideTabs[k] == nil {
                glideTabs[k] = GlideTab(backend: backend, tabID: tabID, jobID: jobID, owner: key, lastUsed: Date())
            }
            glideTabs[k]?.lastUsed = Date()
            var spared = liveTabKeys()
            if let previous { spared.insert(previous) }
            var victims: [GlideTab] = []
            func evict(where include: (GlideTab) -> Bool, cap: Int) {
                while glideTabs.values.filter(include).count > cap {
                    guard let oldest = glideTabs.filter({ include($0.value) && !spared.contains($0.key) })
                        .min(by: { $0.value.lastUsed < $1.value.lastUsed }) else { return }
                    glideTabs[oldest.key] = nil
                    snapshots[oldest.key] = nil
                    victims.append(oldest.value)
                }
            }
            evict(where: { $0.jobID == jobID }, cap: maxTabsPerJob)
            evict(where: { _ in true }, cap: maxTabs)
            return victims
        }
    }

    /// Tab keys that are some session's current tab. Call with the lock held.
    private func liveTabKeys() -> Set<String> {
        Set(sessions.values.map { Self.tabKey($0.backend, $0.tabID) })
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

    func isGlideTab(backend: BrowserBackendKind, tabID: String) -> Bool {
        lock.withLock { glideTabs[Self.tabKey(backend, tabID)] != nil }
    }

    /// True for a tab Glide already accounts for: one it opened, or some session's current tab.
    /// A click's popup is never one of these, so two parallel items can't both adopt a tab.
    func isTracked(backend: BrowserBackendKind, tabID: String) -> Bool {
        lock.withLock {
            let k = Self.tabKey(backend, tabID)
            return glideTabs[k] != nil || liveTabKeys().contains(k)
        }
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

    /// Closes the Glide tabs of one job item (or of the job itself when `itemID` is nil): its
    /// current tab and any it opened and left behind, unless another session works in them now.
    /// The job engine calls this when an item finishes to free its tabs early; otherwise tabs
    /// are recycled least-recently-used.
    public func release(jobID: String?, itemID: String?, hub: BrowserHub = .shared) async {
        let key = Self.key(jobID: jobID, itemID: itemID)
        let victims: [GlideTab] = lock.withLock {
            let current = sessions.removeValue(forKey: key).map { Self.tabKey($0.backend, $0.tabID) }
            let live = liveTabKeys()
            let mine = glideTabs.filter { ($0.value.owner == key || $0.key == current) && !live.contains($0.key) }
            for k in mine.keys { glideTabs[k] = nil }
            return Array(mine.values)
        }
        for v in victims {
            guard let backend = hub.registered(v.backend) else { continue }
            await close([v], driver: driver(for: backend))
        }
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
