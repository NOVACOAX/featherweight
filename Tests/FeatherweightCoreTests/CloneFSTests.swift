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

    /// The `CloneError` thrown by `body`, or nil if it returned or threw something else.
    private func cloneError(_ body: () throws -> Void) -> CloneError? {
        do { try body() } catch let error as CloneError { return error } catch { return nil }
        return nil
    }

    private func flags(of url: URL) -> UInt32 {
        var st = stat()
        _ = lstat(url.path, &st)
        return st.st_flags
    }

    private func regularStat(ino: UInt64, nlink: UInt16 = 1, flags: UInt32 = 0) -> stat {
        var st = stat()
        st.st_dev = 1
        st.st_ino = ino
        st.st_mode = S_IFREG | 0o644
        st.st_nlink = nlink
        st.st_flags = flags
        return st
    }

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

    @Test func privateBytesSkipsHardlinkedFiles() throws {
        let tree = try TempTree(["dir/lone.js": Self.payload, "dir/linked.js": Self.payload])
        defer { tree.remove() }
        #expect(link(tree.url("dir/linked.js").path, tree.url("dir/linked-2.js").path) == 0)
        let lone = try CloneFS.info(at: tree.url("dir/lone.js"))
        #expect(lone.privateSize > 0)
        #expect(try CloneFS.info(at: tree.url("dir/linked.js")).privateSize > 0)
        #expect(CloneFS.privateBytes(under: tree.url("dir")) == lone.privateSize)
    }

    @Test(arguments: [UInt32(UF_IMMUTABLE), UInt32(UF_APPEND)])
    func lockedKeeperLeavesNoTemp(flag: UInt32) throws {
        let (tree, keeper, dup) = try makePair()
        defer { tree.remove() }
        #expect(chflags(keeper.path, flag) == 0)
        defer {
            _ = chflags(keeper.path, 0)
            _ = chflags(dup.path, 0)
        }
        let before = try CloneFS.info(at: dup)
        do {
            try CloneFS.replaceWithClone(of: keeper, replacing: dup)
            #expect(flags(of: dup) & (UInt32(UF_IMMUTABLE) | UInt32(UF_APPEND)) == 0)
            #expect(try CloneFS.info(at: dup).sharesAllBlocks)
        } catch {
            #expect(try CloneFS.info(at: dup).inode == before.inode)
        }
        #expect(try tempFiles(in: dup.deletingLastPathComponent()).isEmpty)
        #expect(try Data(contentsOf: dup) == Data(Self.payload.utf8))
        #expect(flags(of: keeper) == flag)
    }

    @Test func refusesHardlinkedDuplicate() throws {
        let (tree, keeper, dup) = try makePair()
        defer { tree.remove() }
        #expect(link(dup.path, tree.url("dup/other-link.js").path) == 0)
        let before = try CloneFS.info(at: dup)
        let error = cloneError { try CloneFS.replaceWithClone(of: keeper, replacing: dup) }
        guard case .hardlinked? = error else {
            Issue.record("expected hardlinked, got \(String(describing: error))")
            return
        }
        #expect(try CloneFS.info(at: dup).inode == before.inode)
        #expect(try tempFiles(in: dup.deletingLastPathComponent()).isEmpty)
    }

    @Test func refusesSameFile() throws {
        let (tree, keeper, _) = try makePair()
        defer { tree.remove() }
        let samePath = cloneError { try CloneFS.replaceWithClone(of: keeper, replacing: keeper) }
        guard case .sameFile? = samePath else {
            Issue.record("expected sameFile for one path, got \(String(describing: samePath))")
            return
        }
        let alias = tree.url("keep/alias.js")
        #expect(link(keeper.path, alias.path) == 0)
        let hardlink = cloneError { try CloneFS.replaceWithClone(of: keeper, replacing: alias) }
        guard case .sameFile? = hardlink else {
            Issue.record("expected sameFile for a hardlink, got \(String(describing: hardlink))")
            return
        }
        #expect(try tempFiles(in: keeper.deletingLastPathComponent()).isEmpty)
    }

    @Test func refusesCompressedKeeper() throws {
        // `ditto --hfsCompression` does not compress on this machine, so use a decmpfs-compressed
        // file from the read-only system volume as the keeper. Nothing is written to it.
        let bin = URL(fileURLWithPath: "/usr/bin")
        let compressed = try FileManager.default.contentsOfDirectory(atPath: bin.path)
            .map { bin.appendingPathComponent($0) }
            .first { var st = stat(); return lstat($0.path, &st) == 0
                && st.st_mode & S_IFMT == S_IFREG && st.st_flags & UInt32(UF_COMPRESSED) != 0 }
        let keeper = try #require(compressed)
        let tree = try TempTree(["dup/a": Self.payload])
        defer { tree.remove() }
        let error = cloneError { try CloneFS.replaceWithClone(of: keeper, replacing: tree.url("dup/a")) }
        guard case .compressed? = error else {
            Issue.record("expected compressed, got \(String(describing: error))")
            return
        }
        #expect(try Data(contentsOf: tree.url("dup/a")) == Data(Self.payload.utf8))
    }

    @Test func refusalChecksFlagsAndLinks() {
        let keeper = regularStat(ino: 1)
        let compressedFlag = UInt32(UF_COMPRESSED)
        #expect(CloneFS.refusal(keeper: keeper, duplicate: regularStat(ino: 2)) == nil)
        if case .compressed? = CloneFS.refusal(
            keeper: keeper, duplicate: regularStat(ino: 2, flags: compressedFlag)) {} else {
            Issue.record("compressed duplicate not refused")
        }
        if case .compressed? = CloneFS.refusal(
            keeper: regularStat(ino: 1, flags: compressedFlag), duplicate: regularStat(ino: 2)) {} else {
            Issue.record("compressed keeper not refused")
        }
        if case .hardlinked? = CloneFS.refusal(keeper: keeper, duplicate: regularStat(ino: 2, nlink: 2)) {} else {
            Issue.record("hardlinked duplicate not refused")
        }
        #expect(CloneFS.refusal(keeper: regularStat(ino: 1, nlink: 3), duplicate: regularStat(ino: 2)) == nil)
        if case .sameFile? = CloneFS.refusal(keeper: keeper, duplicate: regularStat(ino: 1)) {} else {
            Issue.record("same inode not refused")
        }
    }
}
