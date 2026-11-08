import Darwin
import Foundation
import Testing
@testable import FeatherweightCore

@Suite struct CloneFSTests {
    /// 64 KiB of patterned data, so each file occupies real blocks on APFS.
    static let payload = String(repeating: "featherweight-0123456789abcdef\n", count: 2048)

    /// A tree with `keeper` and `duplicate` holding identical, independently written bytes.
    private func makePair(
        keeper: String = "keep/a.js", duplicate: String = "dup/a.js"
    ) throws -> (TempTree, URL, URL) {
        let tree = try TempTree([keeper: Self.payload, duplicate: Self.payload])
        return (tree, tree.url(keeper), tree.url(duplicate))
    }

    private func setXattr(_ name: String, _ value: String, on url: URL) throws {
        let bytes = Array(value.utf8)
        let rc = setxattr(url.path, name, bytes, bytes.count, 0, XATTR_NOFOLLOW)
        #expect(rc == 0)
    }

    private func getXattr(_ name: String, on url: URL) -> String? {
        var buffer = [UInt8](repeating: 0, count: 256)
        let n = getxattr(url.path, name, &buffer, buffer.count, 0, XATTR_NOFOLLOW)
        return n < 0 ? nil : String(decoding: buffer[0..<n], as: UTF8.self)
    }

    private func mode(of url: URL) -> mode_t {
        var st = stat()
        _ = lstat(url.path, &st)
        return st.st_mode & 0o7777
    }

    private func tempFiles(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains(".fw-") }
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.synchronize()
        try handle.close()
    }

    struct Interrupted: Error {}

    @Test func cloneIsByteIdentical() throws {
        let (tree, keeper, dup) = try makePair(
            keeper: "MAgPIE Studio/keep é.js", duplicate: "Lightroom /dup copy .js")
        defer { tree.remove() }
        try CloneFS.replaceWithClone(of: keeper, replacing: dup)
        #expect(try Data(contentsOf: dup) == Data(contentsOf: keeper))
        #expect(try Data(contentsOf: dup) == Data(Self.payload.utf8))
        #expect(try tempFiles(in: dup.deletingLastPathComponent()).isEmpty)
    }

    @Test func cloneSharesBlocks() throws {
        let (tree, keeper, dup) = try makePair()
        defer { tree.remove() }
        let before = try CloneFS.info(at: dup)
        #expect(!before.sharesAllBlocks)
        #expect(before.privateSize > 0)

        try CloneFS.replaceWithClone(of: keeper, replacing: dup)

        let k = try CloneFS.info(at: keeper)
        let d = try CloneFS.info(at: dup)
        #expect(k.cloneID != 0)
        #expect(k.cloneID == d.cloneID)
        #expect(k.sharesAllBlocks)
        #expect(d.sharesAllBlocks)
        #expect(d.privateSize == 0)
        #expect(d.isRegularFile)
        #expect(d.size == Int64(Self.payload.utf8.count))
        #expect(d.inode != k.inode)
        #expect(d.device == k.device)
    }

    @Test func keepsDuplicateMetadata() throws {
        let (tree, keeper, dup) = try makePair()
        defer { tree.remove() }
        let mtime2020 = Date(timeIntervalSince1970: 1_577_836_800)  // 2020-01-01T00:00:00Z
        #expect(chmod(dup.path, 0o755) == 0)
        try tree.setMTime("dup/a.js", to: mtime2020)
        try setXattr("com.example.x", "1", on: dup)
        #expect(chmod(keeper.path, 0o644) == 0)
        try setXattr("com.example.keeperonly", "k", on: keeper)

        try CloneFS.replaceWithClone(of: keeper, replacing: dup)

        #expect(mode(of: dup) == 0o755)
        #expect(mode(of: keeper) == 0o644)
        let attrs = try FileManager.default.attributesOfItem(atPath: dup.path)
        #expect(attrs[.modificationDate] as? Date == mtime2020)
        #expect(getXattr("com.example.x", on: dup) == "1")
        #expect(getXattr("com.example.keeperonly", on: dup) == nil)
        #expect(getXattr("com.example.keeperonly", on: keeper) == "k")
    }

    @Test func divergesOnWrite() throws {
        let (tree, keeper, dup) = try makePair()
        defer { tree.remove() }
        try CloneFS.replaceWithClone(of: keeper, replacing: dup)
        try append("more\n", to: dup)
        #expect(try Data(contentsOf: keeper) == Data(Self.payload.utf8))
        #expect(try Data(contentsOf: dup) == Data((Self.payload + "more\n").utf8))
        #expect(try !CloneFS.info(at: dup).sharesAllBlocks)
    }

    @Test func interruptedReplaceLeavesOriginal() throws {
        let (tree, keeper, dup) = try makePair()
        defer { tree.remove() }
        let before = try CloneFS.info(at: dup)
        #expect(throws: Interrupted.self) {
            try CloneFS.replaceWithClone(of: keeper, replacing: dup, beforeRename: { throw Interrupted() })
        }
        let after = try CloneFS.info(at: dup)
        #expect(after.inode == before.inode)
        #expect(try Data(contentsOf: dup) == Data(Self.payload.utf8))
        #expect(try tempFiles(in: dup.deletingLastPathComponent()).isEmpty)
    }

    @Test func changedDuringReplaceIsDetected() throws {
        let (tree, keeper, dup) = try makePair()
        defer { tree.remove() }
        var caught: Error?
        do {
            try CloneFS.replaceWithClone(of: keeper, replacing: dup, beforeRename: {
                try append("new write\n", to: dup)
            })
        } catch {
            caught = error
        }
        guard case .changedDuringReplace? = caught as? CloneError else {
            Issue.record("expected changedDuringReplace, got \(String(describing: caught))")
            return
        }
        #expect(try Data(contentsOf: dup) == Data((Self.payload + "new write\n").utf8))
        #expect(try Data(contentsOf: keeper) == Data(Self.payload.utf8))
        #expect(try tempFiles(in: dup.deletingLastPathComponent()).isEmpty)
    }

    @Test func hardlinkReportsLinkCount() throws {
        let tree = try TempTree(["a": Self.payload])
        defer { tree.remove() }
        #expect(link(tree.url("a").path, tree.url("b").path) == 0)
        #expect(try CloneFS.info(at: tree.url("a")).linkCount == 2)
    }

    @Test func refusesSymlinkDuplicate() throws {
        let (tree, keeper, _) = try makePair()
        defer { tree.remove() }
        let link = tree.url("dup/link.js")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: keeper.path)
        var caught: Error?
        do { try CloneFS.replaceWithClone(of: keeper, replacing: link) } catch { caught = error }
        guard case .notRegularFile? = caught as? CloneError else {
            Issue.record("expected notRegularFile, got \(String(describing: caught))")
            return
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == keeper.path)
        #expect(try !CloneFS.info(at: link).isRegularFile)
    }

    @Test func privateBytesSumsRegularFilesWithoutFollowingSymlinks() throws {
        let tree = try TempTree(["dir/a.js": Self.payload, "outside/big.js": Self.payload + Self.payload])
        defer { tree.remove() }
        try FileManager.default.createSymbolicLink(
            atPath: tree.url("dir/outside").path, withDestinationPath: tree.url("outside").path)
        let a = try CloneFS.info(at: tree.url("dir/a.js"))
        #expect(a.privateSize > 0)
        #expect(CloneFS.privateBytes(under: tree.url("dir")) == a.privateSize)
    }
}
