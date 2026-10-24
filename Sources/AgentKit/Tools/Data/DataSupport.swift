import Foundation

// Small synchronous building blocks for the spreadsheet code: running /usr/bin/zip and unzip
// with a timeout, serializing edits per file, atomic replacement with a one-time backup, and
// resolving the paths a model hands us. They are synchronous because `TableIO`'s hooks are
// synchronous; the async tools hop onto a GCD queue (`runBlocking`) so they never block the
// Swift concurrency pool while a zip runs.

/// Errors from reading or changing spreadsheets, worded for the user.
public enum SpreadsheetError: Error, LocalizedError, Sendable {
    case notFound(String)
    case alreadyExists(String)
    case unsupportedFormat(String)
    case unreadable(String)
    case invalid(String)
    case tooLarge(String)
    case protectedCell(String)
    case toolFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let m), .alreadyExists(let m), .unsupportedFormat(let m), .unreadable(let m), .invalid(let m),
             .tooLarge(let m), .protectedCell(let m), .toolFailed(let m):
            return m
        }
    }
}

/// Runs a command-line tool synchronously with a hard timeout.
enum Subprocess {
    struct Result {
        var status: Int32
        var stdout: Data
        var stderr: String
    }

    /// Collects pipe output from background threads.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data()
        private var err = Data()
        func setOut(_ d: Data) { lock.withLock { out = d } }
        func setErr(_ d: Data) { lock.withLock { err = d } }
        var values: (Data, Data) { lock.withLock { (out, err) } }
    }

    /// Output beyond this is drained but dropped, so a runaway tool can't exhaust memory.
    static let maxOutputBytes = 64 << 20

    static func run(_ executable: String, _ arguments: [String], cwd: URL? = nil, stdin: Data? = nil, timeout: TimeInterval = 120) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }
        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = stdin == nil ? FileHandle.nullDevice : inPipe

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch {
            throw SpreadsheetError.toolFailed("Couldn't start \(executable): \(error.localizedDescription)")
        }

        // Drain both pipes concurrently; a full pipe would otherwise deadlock the child.
        let collector = Collector()
        let readers = DispatchGroup()
        for (handle, isOut) in [(outPipe.fileHandleForReading, true), (errPipe.fileHandleForReading, false)] {
            readers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                var buffer = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    if buffer.count < maxOutputBytes { buffer.append(chunk.prefix(maxOutputBytes - buffer.count)) }
                }
                if isOut { collector.setOut(buffer) } else { collector.setErr(buffer) }
                readers.leave()
            }
        }
        if let stdin {
            let writer = inPipe.fileHandleForWriting
            // If the child exits without reading everything, the write must fail with EPIPE
            // rather than raise SIGPIPE, which would terminate Glide itself.
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            DispatchQueue.global(qos: .userInitiated).async {
                try? writer.write(contentsOf: stdin)
                try? writer.close()
            }
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL); _ = finished.wait(timeout: .now() + 2) }
            _ = readers.wait(timeout: .now() + 2)
            throw SpreadsheetError.toolFailed("\((executable as NSString).lastPathComponent) didn't finish within \(Int(timeout)) seconds.")
        }
        _ = readers.wait(timeout: .now() + 5)
        let (out, err) = collector.values
        return Result(status: process.terminationStatus, stdout: out, stderr: String(decoding: err, as: UTF8.self))
    }
}

/// One lock per file so concurrent job items that write back into the same spreadsheet don't
/// lose each other's read-modify-write cycles.
enum FileLocks {
    private static let tableLock = NSLock()
    nonisolated(unsafe) private static var locks: [String: NSLock] = [:]

    static func withLock<T>(_ path: String, _ body: () throws -> T) rethrows -> T {
        let lock = tableLock.withLock { () -> NSLock in
            if let l = locks[path] { return l }
            let l = NSLock()
            locks[path] = l
            return l
        }
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// Tracks which files Glide has backed up (and created), per job. The first in-place change a
/// job makes to a file it didn't create leaves `<file>.bak` with the file as it was, so a bad
/// write-back can always be undone by hand.
///
/// A job can outlive the process (it's resumed after a relaunch, or by `glidectl job resume`),
/// so each backup is also tagged with its owner in an extended attribute. A resumed job sees its
/// own backup and keeps it, instead of replacing the original with its half-written file.
enum FileProvenance {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var backedUp: Set<String> = []
    nonisolated(unsafe) private static var created: Set<String> = []

    /// Keyed by the real path, so "~/x.csv", "./x.csv" and a symlink to it are the same file.
    private static func key(_ owner: String?, _ path: String) -> String { "\(owner ?? "-")\u{1F}\(DataPaths.realPath(path))" }

    static func markCreated(_ path: String, owner: String?) { lock.withLock { _ = created.insert(key(owner, path)) } }
    static func wasCreated(_ path: String, owner: String?) -> Bool { lock.withLock { created.contains(key(owner, path)) } }

    /// Copies `path` to `path.bak` once per owner. Files the owner created itself aren't backed up.
    @discardableResult
    static func backupIfNeeded(_ path: String, owner: String?) throws -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path), !wasCreated(path, owner: owner) else { return nil }
        let k = key(owner, path)
        let needed = lock.withLock { !backedUp.contains(k) }
        guard needed else { return nil }
        let bak = path + ".bak"
        if let owner, isPersistent(owner), backupOwner(bak) == owner {
            lock.withLock { _ = backedUp.insert(k) }
            return nil
        }
        let tmp = (path as NSString).deletingLastPathComponent + "/.\(UUID().uuidString).glide-bak"
        do {
            try fm.copyItem(atPath: path, toPath: tmp)
            if fm.fileExists(atPath: bak) {
                _ = try fm.replaceItemAt(URL(fileURLWithPath: bak), withItemAt: URL(fileURLWithPath: tmp))
            } else {
                try fm.moveItem(atPath: tmp, toPath: bak)
            }
        } catch {
            try? fm.removeItem(atPath: tmp)
            throw SpreadsheetError.toolFailed("Couldn't make a backup copy of “\((path as NSString).lastPathComponent)” before changing it: \(error.localizedDescription)")
        }
        if let owner, isPersistent(owner) { setBackupOwner(bak, owner) }
        lock.withLock { _ = backedUp.insert(k) }
        return bak
    }

    /// Forgets what this process remembers, as a relaunch would (tests use it).
    static func forgetInMemory() { lock.withLock { backedUp.removeAll(); created.removeAll() } }

    /// Quick tasks share one owner name and never resume, so only job owners are remembered
    /// across processes.
    private static func isPersistent(_ owner: String) -> Bool { owner != "quick-task" && owner != "-" }

    static let ownerAttribute = "dev.glide.backup-owner"

    static func backupOwner(_ path: String) -> String? {
        var buffer = [UInt8](repeating: 0, count: 256)
        let n = getxattr(path, ownerAttribute, &buffer, buffer.count, 0, 0)
        guard n > 0 else { return nil }
        return String(decoding: buffer.prefix(n), as: UTF8.self)
    }

    /// Best effort: without the tag a resumed job just makes a fresh backup, as before.
    private static func setBackupOwner(_ path: String, _ owner: String) {
        let bytes = Array(owner.utf8.prefix(255))
        _ = setxattr(path, ownerAttribute, bytes, bytes.count, 0, 0)
    }
}

enum AtomicFile {
    /// A temp path in the same folder as `path`, so the final rename never crosses volumes.
    static func siblingTemp(for path: String, ext: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir + "/.\((path as NSString).lastPathComponent).glide-\(UUID().uuidString.prefix(8)).\(ext)"
    }

    /// Moves `temp` over `path` (or into place when `path` doesn't exist yet).
    static func replace(_ path: String, with temp: String) throws {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: path) {
                _ = try fm.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: temp))
            } else {
                try fm.moveItem(atPath: temp, toPath: path)
            }
        } catch {
            try? fm.removeItem(atPath: temp)
            throw SpreadsheetError.toolFailed("Couldn't save “\((path as NSString).lastPathComponent)”: \(error.localizedDescription)")
        }
    }

    static func write(_ data: Data, to path: String) throws {
        let tmp = siblingTemp(for: path, ext: "tmp")
        do { try data.write(to: URL(fileURLWithPath: tmp)) } catch {
            throw SpreadsheetError.toolFailed("Couldn't write “\((path as NSString).lastPathComponent)”: \(error.localizedDescription)")
        }
        try replace(path, with: tmp)
    }
}

enum DataPaths {
    /// Resolves a model-supplied path: `~`, `file://` URLs, and paths relative to `base`.
    static func resolve(_ raw: String, base: URL) -> String {
        var p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.lowercased().hasPrefix("file://"), let u = URL(string: p), u.isFileURL { p = u.path }
        p = (p as NSString).expandingTildeInPath
        if !p.hasPrefix("/") { p = base.appendingPathComponent(p).path }
        return (p as NSString).standardizingPath
    }

    /// The real location after following symlinks (for the parent when the file doesn't exist yet).
    static func realPath(_ path: String) -> String {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) { return (path as NSString).resolvingSymlinksInPath }
        let parent = ((path as NSString).deletingLastPathComponent as NSString).resolvingSymlinksInPath
        return (parent as NSString).appendingPathComponent((path as NSString).lastPathComponent)
    }

    static var home: String { FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path }

    /// True inside the user's home folder or a temp folder.
    static func isInUserSpace(_ real: String) -> Bool {
        let roots = [home, "/tmp", "/private/tmp", "/private/var/folders", "/var/folders",
                     (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath]
        return roots.contains { real == $0 || real.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    /// Places Glide must never write a spreadsheet into.
    static func forbiddenReason(_ real: String) -> String? {
        let keychains = home + "/Library/Keychains"
        for root in [keychains, "/Library/Keychains", "/System", "/usr", "/bin", "/sbin", "/etc", "/private/etc", "/var/db", "/private/var/db"] {
            if real == root || real.hasPrefix(root + "/") { return "Glide won't write files in \(root)." }
        }
        return nil
    }

    static func isInside(_ real: String, folder: URL?) -> Bool {
        guard let folder else { return false }
        let f = (folder.standardizedFileURL.path as NSString).resolvingSymlinksInPath
        return real.hasPrefix(f.hasSuffix("/") ? f : f + "/")
    }
}

/// Runs blocking work (zip, file I/O) on a GCD queue instead of a Swift concurrency thread.
func runBlocking<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
        DispatchQueue.global(qos: .userInitiated).async {
            do { cont.resume(returning: try body()) } catch { cont.resume(throwing: error) }
        }
    }
}
