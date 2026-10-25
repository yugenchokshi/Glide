import Foundation
import AppKit

/// An app Glide could open: installed in one of the standard folders, or running right now.
public struct InstalledApp: Sendable, Hashable {
    /// What the user sees (the bundle's file name or its display name): "ChatGPT", "zoom.us".
    public var name: String
    public var bundleID: String
    public var url: URL?
    public var isRunning: Bool
    /// Other names the bundle answers to (its CFBundleDisplayName / CFBundleName when they differ).
    public var otherNames: [String]

    public init(name: String, bundleID: String, url: URL? = nil, isRunning: Bool = false, otherNames: [String] = []) {
        self.name = name
        self.bundleID = bundleID
        self.url = url
        self.isRunning = isRunning
        self.otherNames = otherNames
    }
}

/// The apps on this Mac. Behind a protocol so tests resolve names against a fixed list.
public protocol AppIndexing: Sendable {
    func apps() -> [InstalledApp]
}

/// Scans the standard application folders once, lazily, and rescans only when one of them
/// changes (an app was installed, moved or removed — the folder's modification date moves),
/// so a lookup costs a few `stat`s instead of reading hundreds of bundles. Running apps are
/// merged in on every call: they are cheap to list and cover apps launched from anywhere.
public final class SystemAppIndex: AppIndexing, @unchecked Sendable {
    public static let shared = SystemAppIndex()

    let folders: [String]
    private let lock = NSLock()
    private var installed: [InstalledApp] = []
    private var stamps: [String: Date] = [:]
    private var built = false

    public init(folders: [String] = SystemAppIndex.defaultFolders) {
        self.folders = folders
    }

    public static let defaultFolders: [String] = [
        "/Applications", "/Applications/Utilities", NSHomeDirectory() + "/Applications",
        "/System/Applications", "/System/Applications/Utilities",
    ]

    public func apps() -> [InstalledApp] {
        let list = installedApps()
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        var byID: [String: InstalledApp] = [:]
        var order: [String] = []
        for app in list where byID[app.bundleID] == nil {
            byID[app.bundleID] = app
            order.append(app.bundleID)
        }
        for r in running {
            guard let id = r.bundleIdentifier else { continue }
            if byID[id] != nil {
                byID[id]?.isRunning = true
            } else {
                byID[id] = InstalledApp(name: r.localizedName ?? id, bundleID: id, url: r.bundleURL, isRunning: true)
                order.append(id)
            }
        }
        return order.compactMap { byID[$0] }
    }

    /// Builds the folder scan in the background so the first spoken request doesn't pay for it.
    public func warmUp() {
        Task.detached(priority: .utility) { [self] in _ = installedApps() }
    }

    private func installedApps() -> [InstalledApp] {
        let current = folderStamps()
        if let cached = lock.withLock({ built && current == stamps ? installed : nil }) { return cached }
        let scanned = scan()
        lock.withLock {
            installed = scanned
            stamps = current
            built = true
        }
        return scanned
    }

    private func folderStamps() -> [String: Date] {
        var out: [String: Date] = [:]
        let fm = FileManager.default
        for f in folders {
            if let d = (try? fm.attributesOfItem(atPath: f))?[.modificationDate] as? Date { out[f] = d }
        }
        return out
    }

    private func scan() -> [InstalledApp] {
        let fm = FileManager.default
        var out: [InstalledApp] = []
        func add(_ url: URL) {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
            let fileName = url.deletingPathExtension().lastPathComponent
            var others: [String] = []
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let n = bundle.object(forInfoDictionaryKey: key) as? String, !n.isEmpty, n != fileName, !others.contains(n) { others.append(n) }
            }
            out.append(InstalledApp(name: fileName, bundleID: id, url: url, otherNames: others))
        }
        for folder in folders {
            guard let items = try? fm.contentsOfDirectory(atPath: folder) else { continue }
            for item in items {
                let url = URL(fileURLWithPath: folder).appendingPathComponent(item)
                if item.hasSuffix(".app") {
                    add(url)
                } else if !item.hasPrefix("."), folder != "/Applications" || item != "Utilities",
                          let inner = try? fm.contentsOfDirectory(atPath: url.path) {
                    // One level of grouping folders ("Microsoft Office", "Chrome Apps.localized").
                    for sub in inner where sub.hasSuffix(".app") { add(url.appendingPathComponent(sub)) }
                }
            }
        }
        return out
    }
}

/// What a spoken app name resolved to.
public enum AppResolution: Sendable, Hashable {
    case found(InstalledApp, confidence: Double)
    /// Two or more apps fit about equally well; the planner asks which one.
    case ambiguous([InstalledApp])
    case notFound
}

/// Turns a spoken app name ("chat gpt", "vs code", "settings") into one installed app.
///
/// Order matters: a known alias first (so "code" is VS Code, not Xcode), then an exact name,
/// then fuzzy matching — and fuzzy matching only answers when it is both confident and clearly
/// ahead of the runner-up, because opening the wrong app is worse than asking.
public struct AppResolver: Sendable {
    public let index: any AppIndexing
    /// Minimum fuzzy score to accept a match.
    public var threshold = 0.84
    /// How far ahead of the runner-up a fuzzy match must be.
    public var margin = 0.06

    public init(index: any AppIndexing) {
        self.index = index
    }

    /// Spoken names → bundle ids, most likely first. Keys are `compact`-normalized.
    static let aliases: [String: [String]] = {
        let table: [(names: [String], ids: [String])] = [
            (["chatgpt", "chat gpt", "openai", "chatgpt app"], ["com.openai.chat"]),
            (["claude", "claude app", "claude desktop"], ["com.anthropic.claudefordesktop"]),
            (["vs code", "vscode", "visual studio code", "code"], ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]),
            (["chrome", "google chrome"], ["com.google.Chrome", "com.google.Chrome.canary"]),
            (["settings", "system settings", "system preferences", "preferences", "mac settings"], ["com.apple.systempreferences"]),
            (["whatsapp", "whats app"], ["net.whatsapp.WhatsApp", "desktop.WhatsApp"]),
            (["slack"], ["com.tinyspeck.slackmacgap"]),
            (["notion"], ["notion.id"]),
            (["spotify"], ["com.spotify.client"]),
            (["zoom", "zoom us"], ["us.zoom.xos"]),
            (["teams", "microsoft teams", "ms teams"], ["com.microsoft.teams2", "com.microsoft.teams"]),
            (["mail", "apple mail", "email app", "mail app"], ["com.apple.mail"]),
            (["messages", "imessage", "i message", "texts"], ["com.apple.MobileSMS"]),
            (["calendar", "ical", "apple calendar"], ["com.apple.iCal"]),
            (["notes", "apple notes"], ["com.apple.Notes"]),
            (["finder"], ["com.apple.finder"]),
            (["terminal"], ["com.apple.Terminal"]),
            (["iterm", "iterm2", "i term"], ["com.googlecode.iterm2"]),
            (["xcode", "x code"], ["com.apple.dt.Xcode"]),
            (["safari"], ["com.apple.Safari"]),
            (["firefox"], ["org.mozilla.firefox"]),
            (["arc", "arc browser"], ["company.thebrowser.Browser"]),
            (["music", "apple music", "itunes"], ["com.apple.Music"]),
            (["photos"], ["com.apple.Photos"]),
            (["maps", "apple maps"], ["com.apple.Maps"]),
            (["facetime", "face time"], ["com.apple.FaceTime"]),
            (["reminders"], ["com.apple.reminders"]),
            (["preview"], ["com.apple.Preview"]),
            (["textedit", "text edit"], ["com.apple.TextEdit"]),
            (["activity monitor", "task manager"], ["com.apple.ActivityMonitor"]),
            (["app store"], ["com.apple.AppStore"]),
            (["word", "microsoft word"], ["com.microsoft.Word"]),
            (["excel", "microsoft excel"], ["com.microsoft.Excel"]),
            (["powerpoint", "power point", "microsoft powerpoint"], ["com.microsoft.Powerpoint"]),
            (["outlook", "microsoft outlook"], ["com.microsoft.Outlook"]),
            (["discord"], ["com.hnc.Discord"]),
            (["figma"], ["com.figma.Desktop"]),
            (["cursor"], ["com.todesktop.230313mzl4w4u92"]),
            (["telegram"], ["ru.keepcoder.Telegram", "org.telegram.desktop"]),
            (["obsidian"], ["md.obsidian"]),
            (["linear"], ["com.linear"]),
            (["warp"], ["dev.warp.Warp-Stable"]),
            (["calculator"], ["com.apple.calculator"]),
            (["system information"], ["com.apple.SystemProfiler"]),
        ]
        var out: [String: [String]] = [:]
        for row in table { for n in row.names { out[compact(n), default: []].append(contentsOf: row.ids) } }
        return out
    }()

    /// Lowercase letters and digits only: "Chat GPT" = "chatgpt", "zoom.us" = "zoomus".
    public static func compact(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init)).lowercased()
    }

    /// Lowercase words: "Visual Studio Code" → ["visual", "studio", "code"].
    static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    public func resolve(_ spoken: String) -> AppResolution {
        let query = Self.compact(spoken)
        guard query.count >= 2 else { return .notFound }
        let apps = index.apps()
        if let ids = Self.aliases[query] {
            for id in ids {
                if let app = apps.first(where: { $0.bundleID.caseInsensitiveCompare(id) == .orderedSame }) { return .found(app, confidence: 1) }
            }
        }
        let exact = apps.filter { app in
            ([app.name] + app.otherNames).contains { Self.compact($0) == query } || app.bundleID.lowercased() == spoken.lowercased()
        }
        if exact.count == 1, let app = exact.first { return .found(app, confidence: 1) }
        if exact.count > 1 {
            // The same name twice (an old and a new build): the running one is what they mean.
            let running = exact.filter(\.isRunning)
            if running.count == 1, let app = running.first { return .found(app, confidence: 0.95) }
            return .ambiguous(exact)
        }
        let queryWords = Self.words(spoken)
        let scored = apps.map { app in
            (app, ([app.name] + app.otherNames).map { Self.score(query: query, queryWords: queryWords, name: $0) }.max() ?? 0)
        }.filter { $0.1 >= threshold }.sorted { $0.1 > $1.1 }
        guard let best = scored.first else { return .notFound }
        let close = scored.filter { best.1 - $0.1 < margin }
        if close.count > 1 { return .ambiguous(close.map(\.0)) }
        return .found(best.0, confidence: best.1)
    }

    /// 0…1 similarity of a spoken name to an app name. Rewards a whole-word match ("teams" in
    /// "Microsoft Teams") and a long prefix ("photo booth" → "Photo Booth"), forgives one or
    /// two slips of the recognizer ("chat gtp"), and stays low for short partial overlaps.
    static func score(query: String, queryWords: [String], name: String) -> Double {
        let target = compact(name)
        guard !target.isEmpty else { return 0 }
        if target == query { return 1 }
        var best = 0.0
        let nameWords = words(name)
        if queryWords.count < nameWords.count, !queryWords.isEmpty, query.count >= 4 {
            // Every spoken word is a whole word of the name, in order: "teams", "studio code".
            var i = 0
            for w in nameWords where i < queryWords.count && w == queryWords[i] { i += 1 }
            if i == queryWords.count { best = max(best, 0.86 + 0.08 * Double(query.count) / Double(target.count)) }
        }
        if target.hasPrefix(query), query.count >= 4 {
            best = max(best, 0.8 + 0.15 * Double(query.count) / Double(target.count))
        }
        let distance = editDistance(Array(query), Array(target))
        let maxLen = max(query.count, target.count)
        if maxLen >= 5 { best = max(best, 1 - Double(distance) / Double(maxLen)) }
        return best
    }

    /// Optimal-string-alignment distance: insertions, deletions, substitutions and swaps of
    /// neighbours ("gtp" → "gpt") each cost one.
    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1) }
            }
        }
        return d[a.count][b.count]
    }
}
