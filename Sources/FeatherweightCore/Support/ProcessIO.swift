import Foundation

/// Collects what a pipe produces on a background queue so a full pipe buffer can never stall the child.
final class PipeReader: @unchecked Sendable {
    private let lock = NSLock()
    private var collected = Data()
    private let finished = DispatchSemaphore(value: 0)

    init(_ handle: FileHandle) {
        DispatchQueue.global(qos: .utility).async { [self] in
            let data = (try? handle.readToEnd()) ?? Data()
            lock.lock()
            collected = data
            lock.unlock()
            finished.signal()
        }
    }

    /// Waits for end-of-file. Returns nil if `timeout` elapses first.
    func data(timeout: TimeInterval? = nil) -> Data? {
        if let timeout {
            guard finished.wait(timeout: .now() + timeout) == .success else { return nil }
        } else {
            finished.wait()
        }
        lock.lock()
        defer { lock.unlock() }
        return collected
    }
}
