import Foundation

/// Marks a job as being worked on by one process. Glide.app and glidectl share the job store, so
/// without this both could run the same job at once (repeating its sends and writes and
/// overwriting each other's progress), or one could mark the other's live job as interrupted.
///
/// An advisory `flock` on `.runner.lock` in the job's folder, held for as long as a process runs
/// (or plans) the job. The system drops it when the process exits or crashes, so a lock can never
/// outlive its owner. Locks taken through separate `tryAcquire` calls exclude each other even
/// inside one process, so two `JobCenter`s never share a job either.
final class JobRunLock {
    static let fileName = ".runner.lock"

    private var fd: Int32

    private init(fd: Int32) {
        self.fd = fd
    }

    deinit { release() }

    /// Takes the job's lock without waiting. Nil when another process (or another `JobCenter`)
    /// holds it. If the lock file can't be opened at all, the lock is granted anyway: refusing
    /// would stop every job on a disk Glide can't write to, which the job couldn't use either.
    static func tryAcquire(folder: URL) -> JobRunLock? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Close-on-exec, so commands a job starts don't inherit the lock and keep it after Glide exits.
        let fd = open(folder.appendingPathComponent(fileName).path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return JobRunLock(fd: -1) }
        if lock(fd) { return JobRunLock(fd: fd) }
        let busy = errno == EWOULDBLOCK
        close(fd)
        return busy ? nil : JobRunLock(fd: -1)
    }

    /// Whether some other holder has the job's lock right now. A probe that takes and drops it,
    /// so it says nothing about locks this caller already holds.
    static func isHeld(folder: URL) -> Bool {
        let fd = open(folder.appendingPathComponent(fileName).path, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if lock(fd) {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    /// Lets go of the lock. Idempotent.
    func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    private static func lock(_ fd: Int32) -> Bool {
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if errno != EINTR { return false }
        }
        return true
    }
}
