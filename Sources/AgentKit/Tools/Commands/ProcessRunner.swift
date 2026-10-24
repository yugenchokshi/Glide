import Foundation
import Darwin

/// Result of one child process run.
public struct ProcessRunResult: Sendable {
    /// Exit status, 128 + signal number when the process was killed by a signal, or -1 when
    /// the status couldn't be collected.
    public var exitCode: Int32
    /// The signal that ended the process, if any.
    public var signal: Int32?
    public var stdout: Data
    public var stderr: Data
    public var stdoutTruncated: Bool
    public var stderrTruncated: Bool
    public var durationMs: Double
    /// The deadline passed and Glide ended the process group.
    public var timedOut: Bool
    /// The execution gate was stopped (or the task cancelled) and Glide ended the process group.
    public var stopped: Bool
    /// A background process the command started kept its output open after the command
    /// finished; Glide stopped reading instead of waiting for it.
    public var outputLeftOpen: Bool

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

/// Runs a program as a child in its own process group and supervises it.
///
/// Why not `Foundation.Process`: it can't put the child in a new process group, so stopping a
/// shell command would leave its children (`sleep 100 & wait`, pipelines, build tools) running.
/// Here the child is spawned with `POSIX_SPAWN_SETPGROUP`, so the emergency stop or a timeout can
/// signal the whole group: SIGTERM first, SIGKILL two seconds later. Output is collected through
/// non-blocking pipes with dispatch read sources, capped per stream so a chatty command can't
/// exhaust memory (the child keeps running; excess output is discarded). Standard input is
/// `/dev/null`, so nothing can hang waiting for a keyboard.
public enum ProcessRunner {
    public static let defaultOutputCap = 1 << 20
    /// Time between SIGTERM and SIGKILL.
    static let killGrace: TimeInterval = 2
    /// How long to wait for output pipes to close after the command itself exited.
    static let drainGrace: TimeInterval = 1

    /// Environment for child processes: Glide's own, minus anything that looks like a secret
    /// (names containing KEY, TOKEN, SECRET, PASSWORD…), plus settings that stop tools from
    /// waiting on a pager or an interactive prompt nobody can answer.
    public static func sanitizedEnvironment(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        let secretMarkers = ["KEY", "TOKEN", "SECRET", "PASSWORD", "PASSWD", "CREDENTIAL"]
        var env = base.filter { name, _ in
            let upper = name.uppercased()
            return !secretMarkers.contains { upper.contains($0) }
        }
        env["PAGER"] = "cat"
        env["GIT_PAGER"] = "cat"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["TERM"] = env["TERM"] ?? "dumb"
        env["NO_COLOR"] = "1"
        env["HOMEBREW_NO_AUTO_UPDATE"] = env["HOMEBREW_NO_AUTO_UPDATE"] ?? "1"
        return env
    }

    /// Runs `executable` (an absolute path) with `arguments`.
    /// - Throws: `ToolError` when the process can't be started. A non-zero exit, a timeout or a
    ///   stop are reported in the result, never thrown, so callers decide how to present them.
    public static func run(executable: String, arguments: [String], cwd: URL? = nil, environment: [String: String]? = nil,
                           timeout: TimeInterval, gate: ExecutionGate? = nil, outputCap: Int = defaultOutputCap) async throws -> ProcessRunResult {
        for s in [executable] + arguments where s.contains("\u{0}") {
            throw ToolError.invalidArguments("arguments can't contain NUL characters")
        }
        if let cwd {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: cwd.path, isDirectory: &isDir), isDir.boolValue else {
                throw ToolError.invalidArguments("the folder \(cwd.path) doesn't exist")
            }
        }
        let env = environment ?? sanitizedEnvironment()
        let start = Date()
        let spawned = try spawn(executable: executable, arguments: arguments, cwd: cwd, environment: env)
        let pid = spawned.pid
        let queue = DispatchQueue(label: "dev.glide.process.\(pid)")
        let out = OutputSink(fd: spawned.stdoutFD, cap: outputCap, queue: queue)
        let err = OutputSink(fd: spawned.stderrFD, cap: outputCap, queue: queue)

        enum EndReason { case timeout, stopped }
        var reason: EndReason?
        var termSentAt: Date?
        var killed = false
        var status: Int32 = 0
        var exited = false
        var statusLost = false
        var interval: TimeInterval = 0.005

        // Supervise: reap, or end the group on stop/timeout.
        while !exited {
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid { exited = true; break }
            // ECHILD: something else in the process reaped the child, so its status is unknown.
            if r == -1, errno != EINTR { exited = true; statusLost = true; break }
            let now = Date()
            if reason == nil {
                if gate?.isStopped == true || Task.isCancelled { reason = .stopped }
                else if now.timeIntervalSince(start) >= timeout { reason = .timeout }
                if reason != nil { kill(-pid, SIGTERM); termSentAt = now }
            } else if !killed, let t = termSentAt, now.timeIntervalSince(t) >= killGrace {
                kill(-pid, SIGKILL); killed = true
            }
            await pause(interval)
            interval = min(interval * 1.5, 0.05)
        }

        // The leader is gone; wait for the pipes to close (other group members may hold them).
        var leftOpen = false
        if let t = termSentAt {
            // Ending the group: give stragglers the rest of the grace period, then kill.
            let deadline = t.addingTimeInterval(killGrace)
            while !(out.isFinished && err.isFinished), Date() < deadline { await pause(0.02) }
            if !(out.isFinished && err.isFinished) { kill(-pid, SIGKILL) }
            let after = Date().addingTimeInterval(0.5)
            while !(out.isFinished && err.isFinished), Date() < after { await pause(0.02) }
        } else {
            let deadline = Date().addingTimeInterval(drainGrace)
            while !(out.isFinished && err.isFinished), Date() < deadline {
                if gate?.isStopped == true || Task.isCancelled { kill(-pid, SIGKILL); reason = .stopped; break }
                await pause(0.01)
            }
        }
        if !(out.isFinished && err.isFinished) { leftOpen = reason == nil }
        await out.close()
        await err.close()

        var exitCode: Int32 = 0
        var signal: Int32?
        let low = status & 0x7f
        if statusLost { exitCode = -1 }
        else if low == 0 { exitCode = (status >> 8) & 0xff }
        else if low != 0x7f { signal = low; exitCode = 128 + low }

        let o = out.snapshot(), e = err.snapshot()
        return ProcessRunResult(exitCode: exitCode, signal: signal, stdout: o.data, stderr: e.data, stdoutTruncated: o.truncated,
                                stderrTruncated: e.truncated, durationMs: Date().timeIntervalSince(start) * 1000,
                                timedOut: reason == .timeout, stopped: reason == .stopped, outputLeftOpen: leftOpen)
    }

    /// Sleeps without being cut short by task cancellation, so the supervisor loop keeps its
    /// pace (and still kills the process) after the surrounding task was cancelled.
    static func pause(_ seconds: TimeInterval) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { c.resume() }
        }
    }

    private struct Spawned {
        var pid: pid_t
        var stdoutFD: Int32
        var stderrFD: Int32
    }

    private static func spawn(executable: String, arguments: [String], cwd: URL?, environment: [String: String]) throws -> Spawned {
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0 else { throw ToolError.failed("Couldn't create a pipe: \(String(cString: strerror(errno)))") }
        guard pipe(&errPipe) == 0 else {
            close(outPipe[0]); close(outPipe[1])
            throw ToolError.failed("Couldn't create a pipe: \(String(cString: strerror(errno)))")
        }
        // Never leak these into other children Glide starts concurrently.
        for fd in outPipe + errPipe { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        if let cwd { posix_spawn_file_actions_addchdir(&actions, cwd.path) }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // New process group (pgid = child pid); close every descriptor not set up above; reset
        // signal handling, since Glide may ignore SIGPIPE and children must not inherit that.
        let flags = Int32(POSIX_SPAWN_SETPGROUP) | Int32(POSIX_SPAWN_CLOEXEC_DEFAULT) | Int32(POSIX_SPAWN_SETSIGDEF) | Int32(POSIX_SPAWN_SETSIGMASK)
        posix_spawnattr_setflags(&attr, Int16(flags))
        posix_spawnattr_setpgroup(&attr, 0)
        var defaults = sigset_t()
        sigfillset(&defaults)
        sigdelset(&defaults, SIGKILL)
        sigdelset(&defaults, SIGSTOP)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attr, &mask)

        let argv = [executable] + arguments
        let envp = environment.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let rc = withCStringArray(argv) { argvPtr in
            withCStringArray(envp) { envPtr in
                posix_spawn(&pid, executable, &actions, &attr, argvPtr, envPtr)
            }
        }
        close(outPipe[1])
        close(errPipe[1])
        guard rc == 0 else {
            close(outPipe[0]); close(errPipe[0])
            throw ToolError.failed("Couldn't start \((executable as NSString).lastPathComponent): \(String(cString: strerror(rc)))")
        }
        return Spawned(pid: pid, stdoutFD: outPipe[0], stderrFD: errPipe[0])
    }

    private static func withCStringArray<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
        let pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) } + [nil]
        defer { for p in pointers { free(p) } }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}

/// Collects one output stream of a child process. All mutable state is behind `lock`; the
/// read source's handlers run on the process's serial queue.
final class OutputSink: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var truncated = false
    private var finished = false
    private var source: DispatchSourceRead?
    private let cap: Int

    init(fd: Int32, cap: Int, queue: DispatchQueue) {
        self.cap = max(0, cap)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.drain(fd: fd) }
        src.setCancelHandler { [weak self] in
            Darwin.close(fd)
            self?.markFinished()
        }
        source = src
        src.resume()
    }

    deinit {
        // A sink must never outlive its descriptor; cancel closes it.
        source?.cancel()
    }

    /// Reads what is available. Bounded per event so a fast writer can't monopolize the queue
    /// (which would delay cancellation).
    private func drain(fd: Int32) {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        for _ in 0..<16 {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                append(chunk, count: n)
                continue
            }
            if n < 0, errno == EINTR { continue }
            if n < 0, errno == EAGAIN { return }
            // EOF or a real error.
            lock.withLock { source }?.cancel()
            return
        }
    }

    private func append(_ bytes: [UInt8], count: Int) {
        lock.withLock {
            let room = cap - buffer.count
            if room <= 0 { truncated = true; return }
            if count > room {
                buffer.append(contentsOf: bytes[0..<room])
                truncated = true
            } else {
                buffer.append(contentsOf: bytes[0..<count])
            }
        }
    }

    private func markFinished() {
        lock.withLock { finished = true; source = nil }
    }

    var isFinished: Bool { lock.withLock { finished } }

    /// Stops reading (closing the descriptor) even if the writer is still alive.
    func close() async {
        let src = lock.withLock { source }
        src?.cancel()
        // Cancellation is asynchronous; wait briefly so the descriptor is closed when we return.
        let deadline = Date().addingTimeInterval(1)
        while !isFinished, Date() < deadline { await ProcessRunner.pause(0.002) }
    }

    func snapshot() -> (data: Data, truncated: Bool) {
        lock.withLock { (buffer, truncated) }
    }
}
