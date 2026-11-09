import Foundation

/// Calls `onChange` (on the main actor) shortly after files in a directory are created, replaced
/// or removed. Changes that arrive in a burst, such as a job rewriting several files, produce one
/// call. Appending to an existing file does not change its directory, so it is not seen.
final class StateDirectoryWatcher: @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject
    private var pending: DispatchWorkItem?

    /// Nil when the directory cannot be opened.
    init?(directory: URL, delay: TimeInterval = 0.25, onChange: @escaping @MainActor () -> Void) {
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write], queue: .main)
        source.setCancelHandler { close(fd) }
        source.setEventHandler { [weak self] in
            // The source runs on the main queue, so this is the main thread.
            self?.pending?.cancel()
            let work = DispatchWorkItem { MainActor.assumeIsolated { onChange() } }
            self?.pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}
