import Darwin
import Foundation
import Testing
@testable import FeatherweightCore

/// Fake projects for dedupe tests: each has `node_modules/react/index.js` (identical, 64 KiB),
/// a unique file (a different size per project) and an empty file, all modified a day ago.
struct DedupeFixture {
    static let payload = String(repeating: "0123456789abcdef", count: 4096)  // 65536 bytes

    let tree: TempTree
    let names: [String]
    let projects: [Project]
    let cache: HashCache

    init(_ names: [String] = ["a", "b"]) throws {
        var files: [String: String] = [:]
        for (i, name) in names.enumerated() {
            files["\(name)/package.json"] = "{}"
            files["\(name)/node_modules/react/index.js"] = Self.payload
            files["\(name)/node_modules/\(name)-only/unique.js"] = String(repeating: name, count: 100 * (i + 1))
            files["\(name)/node_modules/empty.js"] = ""
        }
        let tree = try TempTree(files)
        try tree.setAllMTimes(to: Date().addingTimeInterval(-86_400))
        self.tree = tree
        self.names = names
        projects = names.map { name in
            Project(
                root: URL(fileURLWithPath: tree.url(name).path, isDirectory: true),
                parentRoot: nil, packageManager: .npm,
                nodeModules: URL(fileURLWithPath: tree.url("\(name)/node_modules").path, isDirectory: true))
        }
        cache = try HashCache(url: tree.url("cache/hashes.sqlite"))
    }

    func index(_ name: String) -> URL { tree.url("\(name)/node_modules/react/index.js") }
    func root(_ name: String) -> String { projects[names.firstIndex(of: name)!].root.path }
    func deduper(quietPeriod: TimeInterval = 60) -> Deduper { Deduper(hashCache: cache, quietPeriod: quietPeriod) }
    func info(_ url: URL) throws -> CloneInfo { try CloneFS.info(at: url) }
}

/// Thread-safe value box for test hooks.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

@Suite struct DeduperTests {
    @Test func dryRunReportsWithoutChanging() throws {
        let f = try DedupeFixture()
        defer { f.tree.remove() }
        let before = try (f.info(f.index("a")), f.info(f.index("b")))

        let report = f.deduper().run(projects: f.projects, dryRun: true)

        #expect(report.bytesFreed > 0)
        #expect(report.filesReplaced == 1)
        #expect(report.errors.isEmpty)
        let after = try (f.info(f.index("a")), f.info(f.index("b")))
        #expect(after.0.inode == before.0.inode)
        #expect(after.1.inode == before.1.inode)
        #expect(!after.0.sharesAllBlocks)
        #expect(!after.1.sharesAllBlocks)
    }

    @Test func runSharesIdenticalFiles() throws {
        let f = try DedupeFixture()
        defer { f.tree.remove() }

        let report = f.deduper().run(projects: f.projects, dryRun: false)

        #expect(report.errors.isEmpty)
        #expect(report.filesReplaced == 1)
        #expect(abs(report.bytesFreed - 65536) <= 4096)
        #expect(report.filesScanned == 6)
        let a = try f.info(f.index("a")), b = try f.info(f.index("b"))
        #expect(a.cloneID == b.cloneID)
        #expect(a.sharesAllBlocks && b.sharesAllBlocks)
        #expect(try Data(contentsOf: f.index("b")) == Data(DedupeFixture.payload.utf8))
    }

    @Test func secondRunIsNoOp() throws {
        let f = try DedupeFixture()
        defer { f.tree.remove() }
        let deduper = f.deduper()
        _ = deduper.run(projects: f.projects, dryRun: false)

        let second = deduper.run(projects: f.projects, dryRun: false)

        #expect(second.filesReplaced == 0)
        #expect(second.bytesFreed == 0)
        #expect(second.perProject.isEmpty)
        #expect(second.errors.isEmpty)
    }

    @Test func skipsHardlinks() throws {
        let f = try DedupeFixture()
        defer { f.tree.remove() }
        // b's index.js becomes a hard link to a's, as in a pnpm store.
        try FileManager.default.removeItem(at: f.index("b"))
        #expect(link(f.index("a").path, f.index("b").path) == 0)
        let before = try f.info(f.index("a"))

        let report = f.deduper().run(projects: f.projects, dryRun: false)

        #expect(report.filesReplaced == 0)
        #expect(report.bytesFreed == 0)
        #expect(report.errors.isEmpty)
        let a = try f.info(f.index("a")), b = try f.info(f.index("b"))
        #expect(a.inode == before.inode && b.inode == before.inode)
        #expect(a.linkCount == 2)
    }

    @Test func skipsSymlinks() throws {
        let f = try DedupeFixture()
        defer { f.tree.remove() }
        try FileManager.default.removeItem(at: f.index("b"))
        try FileManager.default.createSymbolicLink(at: f.index("b"), withDestinationURL: f.index("a"))

        let report = f.deduper().run(projects: f.projects, dryRun: false)

        #expect(report.filesReplaced == 0)
        #expect(report.filesScanned == 5)
        #expect(report.errors.isEmpty)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.index("b").path) == f.index("a").path)
    }

    @Test func skipsRecentFiles() throws {
        let f = try DedupeFixture()
        defer { f.tree.remove() }
        try f.tree.setMTime("b/node_modules/react/index.js", to: Date().addingTimeInterval(-10))
        let before = try f.info(f.index("b"))

        let report = f.deduper().run(projects: f.projects, dryRun: false)

        #expect(report.filesReplaced == 0)
        #expect(report.bytesFreed == 0)
        #expect(try f.info(f.index("b")).inode == before.inode)
    }

    @Test func skipsEmptyAndUniqueFiles() throws {
        let f = try DedupeFixture()
        defer { f.tree.remove() }
        // Same size as each other but different bytes: hashed, never shared.
        try f.tree.add([
            "a/node_modules/same-size/x.js": String(repeating: "x", count: 5000),
            "b/node_modules/same-size/x.js": String(repeating: "y", count: 5000),
        ])
        try f.tree.setAllMTimes(to: Date().addingTimeInterval(-86_400))
        let paths = [
            "a/node_modules/empty.js", "b/node_modules/empty.js",
            "a/node_modules/a-only/unique.js", "b/node_modules/b-only/unique.js",
            "a/node_modules/same-size/x.js", "b/node_modules/same-size/x.js",
        ]
        let before = try paths.map { try f.info(f.tree.url($0)).inode }

        let report = f.deduper().run(projects: f.projects, dryRun: false)

        #expect(report.filesReplaced == 1)  // only react/index.js
        #expect(report.errors.isEmpty)
        let after = try paths.map { try f.info(f.tree.url($0)).inode }
        #expect(after == before)
        #expect(try String(contentsOf: f.tree.url("b/node_modules/same-size/x.js"), encoding: .utf8)
            == String(repeating: "y", count: 5000))
    }

    @Test func keeperChangedSkipsGroup() throws {
        let f = try DedupeFixture()
        defer { f.tree.remove() }
        // Same size, different bytes: only the inode/size/mtime re-check can notice.
        let rewritten = String(repeating: "fedcba9876543210", count: 4096)
        let keeper = f.index("a")  // smallest path, so the keeper
        var deduper = f.deduper()
        deduper.afterHashing = {
            let handle = try! FileHandle(forWritingTo: keeper)
            try! handle.write(contentsOf: Data(rewritten.utf8))
            try! handle.close()
        }

        let report = deduper.run(projects: f.projects, dryRun: false)

        #expect(report.filesReplaced == 0)
        #expect(report.bytesFreed == 0)
        #expect(try String(contentsOf: keeper, encoding: .utf8) == rewritten)
        #expect(try String(contentsOf: f.index("b"), encoding: .utf8) == DedupeFixture.payload)
    }

    @Test func duplicateChangedSkipsFile() throws {
        let f = try DedupeFixture()
        defer { f.tree.remove() }
        let rewritten = String(repeating: "fedcba9876543210", count: 4096)
        let duplicate = f.index("b")
        var deduper = f.deduper()
        deduper.afterHashing = {
            let handle = try! FileHandle(forWritingTo: duplicate)
            try! handle.write(contentsOf: Data(rewritten.utf8))
            try! handle.close()
        }

        let report = deduper.run(projects: f.projects, dryRun: false)

        #expect(report.filesReplaced == 0)
        #expect(try String(contentsOf: duplicate, encoding: .utf8) == rewritten)
        #expect(try String(contentsOf: f.index("a"), encoding: .utf8) == DedupeFixture.payload)
    }

    @Test func perProjectAttribution() throws {
        let f = try DedupeFixture(["a", "b", "c"])
        defer { f.tree.remove() }

        let report = f.deduper().run(projects: f.projects, dryRun: false)

        #expect(report.filesReplaced == 2)
        #expect(f.root("b") != f.root("c"))
        #expect(report.perProject[f.root("a")] == nil)  // holds the keeper
        #expect(abs((report.perProject[f.root("b")] ?? 0) - 65536) <= 4096)
        #expect(abs((report.perProject[f.root("c")] ?? 0) - 65536) <= 4096)
        #expect(report.perProject.values.reduce(0, +) == report.bytesFreed)
    }

    @Test func nestedNodeModulesScannedOnce() throws {
        let f = try DedupeFixture()
        defer { f.tree.remove() }
        // A second project whose node_modules lies inside a's must not double-count a's files.
        let inner = Project(
            root: URL(fileURLWithPath: f.tree.url("a/node_modules/react").path, isDirectory: true),
            parentRoot: f.projects[0].root, packageManager: .none,
            nodeModules: URL(fileURLWithPath: f.tree.url("a/node_modules/react").path, isDirectory: true))

        let report = f.deduper().run(projects: f.projects + [inner], dryRun: true)

        #expect(report.filesScanned == 6)
        #expect(report.filesReplaced == 1)
    }

    @Test func runsAtBackgroundQoS() throws {
        let f = try DedupeFixture()
        defer { f.tree.remove() }
        let seen = Locked<qos_class_t?>(nil)
        var deduper = f.deduper()
        deduper.afterHashing = { seen.value = qos_class_self() }

        _ = deduper.run(projects: f.projects, dryRun: true)

        #expect(seen.value == QOS_CLASS_BACKGROUND)
    }
}
