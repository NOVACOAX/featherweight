import CryptoKit
import Foundation
import Testing
@testable import FeatherweightCore

@Suite struct HashCacheTests {
    private func makeCache(_ tree: TempTree) throws -> HashCache {
        try HashCache(url: tree.url("cache/hashes.sqlite"))
    }

    @Test func digestMatchesCryptoKit() throws {
        let tree = try TempTree(["a.txt": "hello featherweight"])
        defer { tree.remove() }
        let cache = try makeCache(tree)
        let url = tree.url("a.txt")
        let digest = try cache.digest(for: url, info: CloneFS.info(at: url))
        #expect(digest == Data(SHA256.hash(data: Data("hello featherweight".utf8))))
    }

    @Test func largeFileStreamsAcrossChunks() throws {
        let tree = try TempTree()
        defer { tree.remove() }
        let bytes = Data((0..<(2_500_000)).map { UInt8($0 % 251) })
        try bytes.write(to: tree.url("big.bin"))
        let cache = try makeCache(tree)
        let url = tree.url("big.bin")
        let digest = try cache.digest(for: url, info: CloneFS.info(at: url))
        #expect(digest == Data(SHA256.hash(data: bytes)))
    }

    @Test func cachedDigestNotRecomputed() throws {
        let tree = try TempTree(["a.txt": "same"])
        defer { tree.remove() }
        let cache = try makeCache(tree)
        let url = tree.url("a.txt")
        let info = try CloneFS.info(at: url)
        let first = try cache.digest(for: url, info: info)
        let second = try cache.digest(for: url, info: info)
        #expect(first == second)
        #expect(cache.hashesComputed == 1)
    }

    @Test func changedFileRecomputed() throws {
        let tree = try TempTree(["a.txt": "one"])
        defer { tree.remove() }
        try tree.setMTime("a.txt", to: Date(timeIntervalSince1970: 1_000_000))
        let cache = try makeCache(tree)
        let url = tree.url("a.txt")
        let first = try cache.digest(for: url, info: CloneFS.info(at: url))

        try Data("two".utf8).write(to: url)
        try tree.setMTime("a.txt", to: Date(timeIntervalSince1970: 2_000_000))
        let second = try cache.digest(for: url, info: CloneFS.info(at: url))

        #expect(cache.hashesComputed == 2)
        #expect(first != second)
        #expect(second == Data(SHA256.hash(data: Data("two".utf8))))
    }

    @Test func sizeChangeAloneRecomputes() throws {
        let tree = try TempTree(["a.txt": "one"])
        defer { tree.remove() }
        let mtime = Date(timeIntervalSince1970: 1_000_000)
        try tree.setMTime("a.txt", to: mtime)
        let cache = try makeCache(tree)
        let url = tree.url("a.txt")
        let first = try cache.digest(for: url, info: CloneFS.info(at: url))

        // Same inode, same mtime, different size.
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("three!".utf8))
        try handle.close()
        try tree.setMTime("a.txt", to: mtime)
        let info = try CloneFS.info(at: url)
        #expect(info.size == 6)
        let second = try cache.digest(for: url, info: info)

        #expect(cache.hashesComputed == 2)
        #expect(first != second)
    }

    @Test func inodeChangeAloneRecomputes() throws {
        let tree = try TempTree(["a.txt": "aaaa", "staging/new.txt": "bbbb"])
        defer { tree.remove() }
        let mtime = Date(timeIntervalSince1970: 1_000_000)
        try tree.setMTime("a.txt", to: mtime)
        try tree.setMTime("staging/new.txt", to: mtime)
        let cache = try makeCache(tree)
        let url = tree.url("a.txt")
        let before = try CloneFS.info(at: url)
        let first = try cache.digest(for: url, info: before)

        // Replace by rename: same path, size and mtime, new inode.
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tree.url("staging/new.txt"))
        try tree.setMTime("a.txt", to: mtime)
        let after = try CloneFS.info(at: url)
        #expect(after.inode != before.inode)
        #expect(after.size == before.size)
        #expect(after.mtimeNanos == before.mtimeNanos)
        let second = try cache.digest(for: url, info: after)

        #expect(cache.hashesComputed == 2)
        #expect(first != second)
    }

    @Test func persistsAcrossInstances() throws {
        let tree = try TempTree(["a.txt": "persist"])
        defer { tree.remove() }
        let url = tree.url("a.txt")
        let info = try CloneFS.info(at: url)
        let first = try makeCache(tree).digest(for: url, info: info)

        let reopened = try makeCache(tree)
        let second = try reopened.digest(for: url, info: info)
        #expect(first == second)
        #expect(reopened.hashesComputed == 0)
    }

    @Test func pathsWithSpacesAndUnicodeAreBoundSafely() throws {
        let tree = try TempTree(["dir/na'me \"x\" é .txt ": "odd"])
        defer { tree.remove() }
        let cache = try makeCache(tree)
        let url = tree.url("dir/na'me \"x\" é .txt ")
        let info = try CloneFS.info(at: url)
        _ = try cache.digest(for: url, info: info)
        _ = try cache.digest(for: url, info: info)
        #expect(cache.hashesComputed == 1)
    }

    @Test func pruneRemovesOtherPaths() throws {
        let tree = try TempTree(["keep/a.txt": "a", "drop/b.txt": "b", "keep2/c.txt": "c"])
        defer { tree.remove() }
        let cache = try makeCache(tree)
        for rel in ["keep/a.txt", "drop/b.txt", "keep2/c.txt"] {
            let url = tree.url(rel)
            _ = try cache.digest(for: url, info: CloneFS.info(at: url))
        }
        #expect(cache.hashesComputed == 3)

        try cache.prune(keepingPathsWithPrefixes: [tree.url("keep").path + "/"])

        for rel in ["keep/a.txt", "drop/b.txt", "keep2/c.txt"] {
            let url = tree.url(rel)
            _ = try cache.digest(for: url, info: CloneFS.info(at: url))
        }
        // Only keep/a.txt survived the prune; the other two were hashed again.
        #expect(cache.hashesComputed == 5)
    }
}
