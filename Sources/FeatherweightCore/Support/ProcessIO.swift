import Foundation

/// Collects what a pipe produces on a background queue so a full pipe buffer can never stall the child.
/// Output is appended as it arrives, so a caller that gives up waiting still gets the partial output.
final class PipeReader: @unchecked Sendable {
    private let lock = NSLock()
    private var collected = Data()
    private let finished = DispatchSemaphore(value: 0)

    init(_ handle: FileHandle) {
        // A dedicated thread, not GCD: the read blocks indefinitely when a background process keeps the
        // pipe open, which would starve the shared dispatch thread pool.
        let thread = Thread { [self] in
            let descriptor = handle.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { break }
                lock.lock()
                collected.append(contentsOf: buffer[..<count])
                lock.unlock()
            }
            finished.signal()
        }
        thread.qualityOfService = .utility
        thread.start()
    }

    /// Waits up to `timeout` for end-of-file (forever when nil) and returns what has arrived so far.
    /// `complete` is false when the timeout elapsed first, for instance because a background process
    /// still holds the pipe's write end open.
    func read(timeout: TimeInterval? = nil) -> (data: Data, complete: Bool) {
        var complete = true
        if let timeout {
            complete = finished.wait(timeout: .now() + timeout) == .success
        } else {
            finished.wait()
        }
        lock.lock()
        defer { lock.unlock() }
        return (collected, complete)
    }
}
