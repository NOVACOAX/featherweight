import CoreServices
import Foundation

struct FileEvent: Sendable {
    let path: String
    let id: UInt64
}

/// One `FSEventStream` with file-level events over a set of folders, delivered on the main queue
/// in batches (5-second latency).
@MainActor
final class FSEventsWatcher {
    private static let latency: CFTimeInterval = 5
    private var stream: FSEventStreamRef?
    private let handler: @MainActor ([FileEvent]) -> Void

    init(handler: @escaping @MainActor ([FileEvent]) -> Void) {
        self.handler = handler
    }

    /// Watches `folders` from now on, replacing any previous stream. An empty list just stops.
    func watch(_ folders: [String]) {
        stop()
        guard !folders.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
            copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, Self.callback, &context, folders as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.latency, flags)
        else {
            HelperLog.line("could not watch \(folders.joined(separator: ", "))")
            return
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            HelperLog.line("could not start watching \(folders.joined(separator: ", "))")
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func deliver(_ events: [FileEvent]) {
        handler(events)
    }

    private static let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, eventIDs in
        guard let info else { return }
        let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
        // With kFSEventStreamCreateFlagUseCFTypes the paths arrive as a CFArray of CFString.
        let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
        var events: [FileEvent] = []
        events.reserveCapacity(count)
        for index in 0..<min(count, paths.count) {
            events.append(FileEvent(path: paths[index], id: eventIDs[index]))
        }
        // The stream is scheduled on the main queue, so this runs on the main thread.
        MainActor.assumeIsolated { watcher.deliver(events) }
    }
}
