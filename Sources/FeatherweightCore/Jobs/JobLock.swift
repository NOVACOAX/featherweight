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

    /// Takes the lock if it is free. Returns false when another holder has it, or the lock file
    /// cannot be opened.
    public func tryLock() -> Bool {
        guard let fd = descriptor() else { return false }
        return flock(fd, LOCK_EX | LOCK_NB) == 0
    }

    /// Blocks until the lock is acquired.
    public func lock() {
        guard let fd = descriptor() else { return }
        while flock(fd, LOCK_EX) != 0 && errno == EINTR {}
    }

    public func unlock() {
        guard let fd = descriptor() else { return }
        flock(fd, LOCK_UN)
    }

    private func descriptor() -> Int32? {
        stateLock.lock()
        defer { stateLock.unlock() }
        if fd >= 0 { return fd }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let opened = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard opened >= 0 else { return nil }
        fd = opened
        return opened
    }
}
