import Foundation
import Testing
@testable import FeatherweightCore

@Suite struct ActivityCheckerTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    let checker = ActivityChecker(now: { ActivityCheckerTests.now })
    let day: TimeInterval = 24 * 3600

    private func ago(_ seconds: TimeInterval) -> Date { Self.now.addingTimeInterval(-seconds) }

    @Test func activityRecentFileIsActive() throws {
        let tree = try TempTree(["a/package.json": "{}", "a/src/index.ts": ""])
        defer { tree.remove() }
        try tree.setAllMTimes(to: ago(2 * day))
        try tree.setMTime("a/src/index.ts", to: ago(3600))
        #expect(checker.isActive(root: tree.url("a"), window: day))
    }

    @Test func activityOldFilesInactive() throws {
        let tree = try TempTree(["a/package.json": "{}", "a/src/index.ts": ""])
        defer { tree.remove() }
        try tree.setAllMTimes(to: ago(2 * day))
        #expect(!checker.isActive(root: tree.url("a"), window: day))
    }

    @Test func activityIgnoresGitDir() throws {
        let tree = try TempTree(["a/package.json": "{}", "a/.git/index": "", "a/src/index.ts": ""])
        defer { tree.remove() }
        try tree.setAllMTimes(to: ago(2 * day))
        try tree.setMTime("a/.git/index", to: ago(60))
        #expect(!checker.isActive(root: tree.url("a"), window: day))
    }

    @Test func nestedActivityMakesParentActive() throws {
        let tree = try TempTree(["a/package.json": "{}", "a/functions/package.json": "{}", "a/functions/index.js": ""])
        defer { tree.remove() }
        try tree.setAllMTimes(to: ago(2 * day))
        try tree.setMTime("a/functions/index.js", to: ago(600))
        #expect(checker.isActive(root: tree.url("a"), window: day))
    }

    @Test func doesNotFollowSymlinks() throws {
        let tree = try TempTree(["a/package.json": "{}", "outside/new.txt": ""])
        defer { tree.remove() }
        try tree.setAllMTimes(to: ago(2 * day))
        try tree.setMTime("outside/new.txt", to: ago(60))
        try FileManager.default.createSymbolicLink(
            atPath: tree.url("a/link").path, withDestinationPath: tree.url("outside").path)
        #expect(!checker.isActive(root: tree.url("a"), window: day))
    }

    @Test func lastSourceChangeExcludesNodeModulesAndGit() throws {
        let tree = try TempTree([
            "a/package.json": "{}", "a/src/x.ts": "",
            "a/node_modules/y/z.js": "", "a/.git/index": "",
        ])
        defer { tree.remove() }
        try tree.setAllMTimes(to: ago(5 * day))
        try tree.setMTime("a/src/x.ts", to: ago(2 * day))
        try tree.setMTime("a/node_modules/y/z.js", to: ago(60))
        try tree.setMTime("a/.git/index", to: ago(30))
        let last = try #require(checker.lastSourceChange(root: tree.url("a")))
        #expect(abs(last.timeIntervalSince(ago(2 * day))) < 1)
    }

    @Test func lastSourceChangeNilForEmptyDir() throws {
        let tree = try TempTree(["a/": ""])
        defer { tree.remove() }
        #expect(checker.lastSourceChange(root: tree.url("a")) == nil)
    }
}
