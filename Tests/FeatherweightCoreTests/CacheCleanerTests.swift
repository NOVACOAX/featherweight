import Foundation
import Testing

@testable import FeatherweightCore

@Suite struct CacheCleanerTests {
    private let oldDate = Date(timeIntervalSinceNow: -30 * 24 * 3600)
    private let megabyte = String(repeating: "x", count: 1_000_000)

    private func cleaner() -> CacheCleaner {
        CacheCleaner(git: GitClient(runner: GitFixture.runner), activity: ActivityChecker())
    }

    private func settings(_ extra: [CacheFolderSetting] = []) -> Settings {
        var s = Settings.defaults(home: FileManager.default.temporaryDirectory)
        s.cacheFolders += extra
        return s
    }

    private func project(_ root: URL) -> Project {
        Project(root: root, parentRoot: nil, packageManager: .npm, nodeModules: nil)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    @Test func cleanerClearsEnabledUntrackedInactive() throws {
        let tree = try TempTree(["src/index.ts": "x", ".next/cache.bin": megabyte])
        defer { tree.remove() }
        try tree.setAllMTimes(to: oldDate)

        let report = cleaner().run(projects: [project(tree.root)], settings: settings(), dryRun: false)

        #expect(!exists(tree.url(".next")))
        #expect(report.bytesFreed >= 1_000_000)
        #expect(report.cleared.map(\.relativePath) == [".next"])
        #expect(report.cleared.first?.folder == tree.url(".next").path)
        #expect(report.cleared.first?.projectRoot == tree.root.path)
        #expect(report.errors.isEmpty)
        #expect(exists(tree.url("src/index.ts")))
    }

    @Test func cleanerSkipsOutputByDefault() throws {
        let tree = try TempTree(["src/index.ts": "x", ".output/server.js": "y"])
        defer { tree.remove() }
        try tree.setAllMTimes(to: oldDate)

        let report = cleaner().run(projects: [project(tree.root)], settings: settings(), dryRun: false)

        #expect(exists(tree.url(".output")))
        #expect(report.skipped.map(\.relativePath) == [".output"])
        #expect(report.skipped.first?.skip == .notEnabled)
        #expect(report.cleared.isEmpty)
    }

    @Test func cleanerSkipsTracked() throws {
        let tree = try TempTree(["src/index.ts": "x", ".cache/keep.txt": "k"])
        defer { tree.remove() }
        try GitFixture.initRepo(tree.root)
        try tree.setAllMTimes(to: oldDate)

        let report = cleaner().run(projects: [project(tree.root)], settings: settings(), dryRun: false)

        #expect(exists(tree.url(".cache/keep.txt")))
        #expect(report.skipped.first { $0.relativePath == ".cache" }?.skip == .trackedInGit)
        #expect(report.cleared.isEmpty)
    }

    @Test func cleanerSkipsRecentlyActive() throws {
        let tree = try TempTree(["src/index.ts": "x", ".next/a": "y"])
        defer { tree.remove() }
        try tree.setAllMTimes(to: oldDate)
        try tree.setMTime("src/index.ts", to: Date())

        let report = cleaner().run(projects: [project(tree.root)], settings: settings(), dryRun: false)

        #expect(exists(tree.url(".next/a")))
        #expect(report.skipped.first?.skip == .recentlyActive)
        #expect(report.cleared.isEmpty)
    }

    @Test func trackedIsReportedBeforeRecentlyActive() throws {
        let tree = try TempTree(["src/index.ts": "x", ".cache/keep.txt": "k"])
        defer { tree.remove() }
        try GitFixture.initRepo(tree.root)  // files are fresh, so the project is also active

        let plan = cleaner().plan(projects: [project(tree.root)], settings: settings())
        #expect(plan.first { $0.relativePath == ".cache" }?.skip == .trackedInGit)
    }

    @Test func activityWindowComesFromSettings() throws {
        let tree = try TempTree(["src/index.ts": "x", ".next/a": "y"])
        defer { tree.remove() }
        try tree.setAllMTimes(to: Date(timeIntervalSinceNow: -2 * 3600))

        var s = settings()
        s.activityWindowHours = 1
        #expect(cleaner().plan(projects: [project(tree.root)], settings: s).first?.skip == nil)
        s.activityWindowHours = 3
        #expect(cleaner().plan(projects: [project(tree.root)], settings: s).first?.skip == .recentlyActive)
    }

    @Test func cleanerNodeModulesCache() throws {
        let tree = try TempTree(["src/index.ts": "x", "node_modules/.cache/babel/a": "y", "node_modules/pkg/index.js": "z"])
        defer { tree.remove() }
        try tree.setAllMTimes(to: oldDate)

        let report = cleaner().run(projects: [project(tree.root)], settings: settings(), dryRun: false)

        #expect(!exists(tree.url("node_modules/.cache")))
        #expect(exists(tree.url("node_modules/pkg/index.js")))
        #expect(report.cleared.map(\.relativePath) == ["node_modules/.cache"])
    }

    @Test func cleanerDryRunDeletesNothing() throws {
        let tree = try TempTree(["src/index.ts": "x", ".next/cache.bin": megabyte])
        defer { tree.remove() }
        try tree.setAllMTimes(to: oldDate)

        let report = cleaner().run(projects: [project(tree.root)], settings: settings(), dryRun: true)

        #expect(exists(tree.url(".next/cache.bin")))
        #expect(report.cleared.map(\.relativePath) == [".next"])
        #expect(report.bytesFreed >= 1_000_000)
    }

    @Test func cleanerCustomFolder() throws {
        let tree = try TempTree(["src/index.ts": "x", "storybook-static/index.html": "y"])
        defer { tree.remove() }
        try tree.setAllMTimes(to: oldDate)
        let custom = CacheFolderSetting(relativePath: "storybook-static", enabled: true, isBuiltIn: false)

        let report = cleaner().run(
            projects: [project(tree.root)], settings: settings([custom]), dryRun: false)

        #expect(!exists(tree.url("storybook-static")))
        #expect(report.cleared.map(\.relativePath) == ["storybook-static"])
    }

    @Test func missingFoldersAndFilesAreIgnored() throws {
        let tree = try TempTree(["src/index.ts": "x", ".next": "a file, not a folder"])
        defer { tree.remove() }
        try tree.setAllMTimes(to: oldDate)

        let plan = cleaner().plan(projects: [project(tree.root)], settings: settings())
        #expect(plan.isEmpty)
    }

    @Test func nestedProjectInsideParentRepo() throws {
        let tree = try TempTree([
            "package.json": "{}", "functions/src/a.ts": "x", "functions/.cache/keep": "k",
            "functions/.next/a": "y",
        ])
        defer { tree.remove() }
        try GitFixture.git(["init", "-q", "-b", "main"], in: tree.root)
        try GitFixture.git(["add", "functions/.cache/keep", "package.json", "functions/src/a.ts"], in: tree.root)
        try GitFixture.git(["commit", "-q", "-m", "init"], in: tree.root)
        try tree.setAllMTimes(to: oldDate)
        let nested = Project(root: tree.url("functions"), parentRoot: tree.root, packageManager: .npm, nodeModules: nil)

        let report = cleaner().run(projects: [nested], settings: settings(), dryRun: false)

        #expect(exists(tree.url("functions/.cache/keep")))
        #expect(!exists(tree.url("functions/.next")))
        #expect(report.skipped.first { $0.relativePath == ".cache" }?.skip == .trackedInGit)
    }

    @Test func pathsWithSpaces() throws {
        let tree = try TempTree([
            "Lightroom /src/index.ts": "x",
            "Lightroom /.next/cache.bin": megabyte,
            "Lightroom /.cache/keep.txt": "k",
            "Lightroom /.vite/a": "v",
        ])
        defer { tree.remove() }
        try GitFixture.git(["init", "-q", "-b", "main"], in: tree.root)
        try GitFixture.git(["add", "--", "Lightroom /src/index.ts", "Lightroom /.cache/keep.txt"], in: tree.root)
        try GitFixture.git(["commit", "-q", "-m", "init"], in: tree.root)
        try tree.setAllMTimes(to: oldDate)
        let spaced = project(tree.url("Lightroom "))

        let dry = cleaner().run(projects: [spaced], settings: settings(), dryRun: true)
        #expect(dry.cleared.map(\.relativePath).sorted() == [".next", ".vite"])
        #expect(exists(tree.url("Lightroom /.next/cache.bin")))

        let report = cleaner().run(projects: [spaced], settings: settings(), dryRun: false)

        #expect(!exists(tree.url("Lightroom /.next")))
        #expect(!exists(tree.url("Lightroom /.vite")))
        #expect(exists(tree.url("Lightroom /.cache/keep.txt")))
        #expect(report.skipped.first { $0.relativePath == ".cache" }?.skip == .trackedInGit)
        #expect(report.bytesFreed >= 1_000_000)
        #expect(report.errors.isEmpty)
    }

    @Test func spacedProjectIsItselfTheRepo() throws {
        let tree = try TempTree(["Lightroom /src/index.ts": "x", "Lightroom /.cache/keep.txt": "k", "Lightroom /.next/a": "y"])
        defer { tree.remove() }
        let root = tree.url("Lightroom ")
        try GitFixture.git(["init", "-q", "-b", "main"], in: root)
        try GitFixture.git(["add", "src/index.ts", ".cache/keep.txt"], in: root)
        try GitFixture.git(["commit", "-q", "-m", "init"], in: root)
        try tree.setAllMTimes(to: oldDate)

        let git = GitClient(runner: GitFixture.runner)
        #expect(git.repoRoot(for: root)?.path == root.path)
        let report = cleaner().run(projects: [project(root)], settings: settings(), dryRun: false)
        #expect(exists(root.appendingPathComponent(".cache/keep.txt")))
        #expect(!exists(root.appendingPathComponent(".next")))
        #expect(report.skipped.first { $0.relativePath == ".cache" }?.skip == .trackedInGit)
    }
}
