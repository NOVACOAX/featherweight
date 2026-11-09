import Darwin
import Foundation

/// Cross-process mutual exclusion for jobs, backed by `flock(LOCK_EX)` on an open file descriptor.
/// The kernel releases the lock if the process dies. Each instance has its own descriptor, so two
/// instances on one file exclude each other even inside a single process.
public final class JobLock: @unchecked Sendable {
    private let url: URL
    private let stateLock = NSLock()
    private var fd: Int32 = -1

    public init(url: URL) {
        self.url = url
    }

    deinit {
        if fd >= 0 { close(fd) }  // closing the descriptor also drops the lock
    }

    /// Takes the lock if it is free. Returns false when another holder has it. Throws when the
    /// lock file cannot be opened or locked, so callers never mistake that for "free".
    public func tryAcquire() throws -> Bool {
        let fd = try descriptor()
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return true }
            switch errno {
            case EWOULDBLOCK: return false
            case EINTR: continue
            default: throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    /// Like `tryAcquire`, but false for any failure (the lock was not taken).
    public func tryLock() -> Bool {
        (try? tryAcquire()) ?? false
    }

    /// Blocks until the lock is held. Throws if the lock file cannot be opened or locked.
    public func lock() throws {
        let fd = try descriptor()
        while flock(fd, LOCK_EX) != 0 {
            if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }

    public func unlock() {
        stateLock.lock()
        defer { stateLock.unlock() }
        if fd >= 0 { flock(fd, LOCK_UN) }
    }

    private func descriptor() throws -> Int32 {
        stateLock.lock()
        defer { stateLock.unlock() }
        if fd >= 0 { return fd }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let opened = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard opened >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        fd = opened
        return opened
    }
}
