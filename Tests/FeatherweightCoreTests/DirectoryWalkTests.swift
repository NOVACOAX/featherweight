import Foundation
import Testing
@testable import FeatherweightCore

/// Counts live instances, to see when autoreleased objects are actually freed.
private final class Tracked: NSObject, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var alive = 0
    override init() {
        Self.lock.lock(); Self.alive += 1; Self.lock.unlock()
        super.init()
    }
    deinit { Self.lock.lock(); Self.alive -= 1; Self.lock.unlock() }
    static var count: Int { lock.lock(); defer { lock.unlock() }; return alive }
}

/// Like the system enumerator (whose per-entry lookups go through FileProvider in an app), each
/// `nextObject()` call leaves an autoreleased object behind.
private final class LitteringEnumerator: FileManager.DirectoryEnumerator {
    private var remaining: Int

    init(entries: Int) {
        remaining = entries
        super.init()
    }

    override func nextObject() -> Any? {
        guard remaining > 0 else { return nil }
        remaining -= 1
        _ = Unmanaged.passRetained(Tracked()).autorelease()
        return URL(fileURLWithPath: "/tmp/entry-\(remaining)")
    }
}

@Suite(.serialized) struct DirectoryWalkTests {
    @Test func objectsMadeWhileFetchingAnEntryAreFreedBeforeTheNext() {
        // On a fresh thread whose own pool is drained only when it exits, as the jobs run.
        let (visited, mostAlive) = BackgroundWork.run { () -> (Int, Int) in
            let walker = LitteringEnumerator(entries: 500)
            var visited = 0
            var mostAlive = 0
            walker.forEachURL { _ in
                visited += 1
                mostAlive = max(mostAlive, Tracked.count)
                return true
            }
            return (visited, mostAlive)
        }
        #expect(visited == 500)
        #expect(mostAlive <= 1)
    }

    @Test func returningFalseStopsTheWalk() {
        let walker = LitteringEnumerator(entries: 10)
        var visited = 0
        walker.forEachURL { _ in
            visited += 1
            return visited < 3
        }
        #expect(visited == 3)
    }

    @Test func walksARealTree() throws {
        let tree = try TempTree(["a/b.txt": "1", "a/c/d.txt": "2", "e.txt": "3"])
        defer { tree.remove() }
        var names: [String] = []
        FileManager.default.enumerator(at: tree.root, includingPropertiesForKeys: nil)?.forEachURL { url in
            names.append(url.lastPathComponent)
            return true
        }
        #expect(names.sorted() == ["a", "b.txt", "c", "d.txt", "e.txt"])
    }
}
