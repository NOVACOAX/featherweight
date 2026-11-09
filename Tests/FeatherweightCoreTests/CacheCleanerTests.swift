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

    // MARK: - Safety

    @Test(arguments: ["", ".", "..", "../sibling", "a/../..", "./", "/etc", ".git", "node_modules", "a//b", "x/.git/y", ".GIT", ".Git/x", "a/.gIt/b", "NODE_MODULES", "Node_Modules"])
    func unsafeRelativePathsAreRejected(path: String) {
        #expect(!CacheFolderSetting.isSafeRelativePath(path))
    }

    @Test(arguments: [".next", "node_modules/.cache", "storybook-static", "a/b/c", ".gitignore-cache"])
    func safeRelativePathsAreAccepted(path: String) {
        #expect(CacheFolderSetting.isSafeRelativePath(path))
    }

    @Test(arguments: ["", ".", "../sibling", "a/../..", ".git", "node_modules", ".GIT", ".Git/x", "NODE_MODULES", "Node_Modules"])
    func unsafeConfiguredPathsNeverDeleteAnything(path: String) throws {
        let tree = try TempTree([
            "proj/src/index.ts": "x", "proj/node_modules/pkg/index.js": "z", "sibling/keep.txt": "k",
            "proj/.next/a": "y",
        ])
        defer { tree.remove() }
        try GitFixture.git(["init", "-q", "-b", "main"], in: tree.url("proj"))
        try tree.setAllMTimes(to: oldDate)
        let bad = CacheFolderSetting(relativePath: path, enabled: true, isBuiltIn: false)
        var s = settings([bad])
        s.cacheFolders = [bad]  // only the unsafe entry

        let projectRoot = tree.url("proj")
        let report = cleaner().run(projects: [project(projectRoot)], settings: s, dryRun: false)

        #expect(report.cleared.isEmpty)
        #expect(report.bytesFreed == 0)
        #expect(!report.errors.isEmpty)
        #expect(exists(tree.url("sibling/keep.txt")))
        #expect(exists(tree.url("proj/src/index.ts")))
        #expect(exists(tree.url("proj/node_modules/pkg/index.js")))
        #expect(exists(tree.url("proj/.git")))
        #expect(exists(tree.url("proj/.next/a")))
        #expect(cleaner().plan(projects: [project(projectRoot)], settings: s).isEmpty)
    }

    @Test func symlinkedNodeModulesCannotEscapeTheProject() throws {
        let tree = try TempTree([
            "proj/src/index.ts": "x", "outside/.cache/secret": "s", "outside/.vite/v": "v",
        ])
        defer { tree.remove() }
        try FileManager.default.createSymbolicLink(
            at: tree.url("proj/node_modules"), withDestinationURL: tree.url("outside"))
        try tree.setAllMTimes(to: oldDate)

        let projectRoot = tree.url("proj")
        let report = cleaner().run(projects: [project(projectRoot)], settings: settings(), dryRun: false)

        #expect(exists(tree.url("outside/.cache/secret")))
        #expect(exists(tree.url("outside/.vite/v")))
        #expect(report.cleared.isEmpty)
        #expect(cleaner().plan(projects: [project(projectRoot)], settings: settings()).isEmpty)
    }

    @Test func symlinkedIntermediateDirectoryInsideTheProjectIsAlsoSkipped() throws {
        let tree = try TempTree(["proj/src/index.ts": "x", "proj/real/dist-cache/a": "y"])
        defer { tree.remove() }
        try FileManager.default.createSymbolicLink(
            at: tree.url("proj/link"), withDestinationURL: tree.url("proj/real"))
        try tree.setAllMTimes(to: oldDate)
        let custom = CacheFolderSetting(relativePath: "link/dist-cache", enabled: true, isBuiltIn: false)
        var s = settings()
        s.cacheFolders = [custom]

        let report = cleaner().run(projects: [project(tree.url("proj"))], settings: s, dryRun: false)

        #expect(exists(tree.url("proj/real/dist-cache/a")))
        #expect(report.cleared.isEmpty)
    }

    @Test func symlinkedCacheFolderIsLeftAlone() throws {
        let tree = try TempTree(["proj/src/index.ts": "x", "outside/a": "o"])
        defer { tree.remove() }
        try FileManager.default.createSymbolicLink(
            at: tree.url("proj/.next"), withDestinationURL: tree.url("outside"))
        try tree.setAllMTimes(to: oldDate)

        let report = cleaner().run(projects: [project(tree.url("proj"))], settings: settings(), dryRun: false)
        #expect(exists(tree.url("outside/a")))
        #expect(report.cleared.isEmpty)
    }

    @Test func gitFailureSkipsTheFolderAndReportsTheError() throws {
        let tree = try TempTree(["src/index.ts": "x", ".next/a": "y"])
        defer { tree.remove() }
        try tree.setAllMTimes(to: oldDate)
        let failing = FakeRunner { _, _ in
            CommandResult(exitCode: 1, stdout: "", stderr: "fatal: detected dubious ownership")
        }
        let cleaner = CacheCleaner(git: GitClient(runner: failing), activity: ActivityChecker())

        let report = cleaner.run(projects: [project(tree.root)], settings: settings(), dryRun: false)

        #expect(exists(tree.url(".next/a")))
        #expect(report.cleared.isEmpty)
        #expect(report.skipped.first?.skip == .gitUnavailable)
        #expect(report.errors.count == 1)
        #expect(report.errors.first?.contains("dubious ownership") == true)
    }

    @Test func gitExitCode128WithAnotherMessageIsAnErrorToo() throws {
        let tree = try TempTree(["src/index.ts": "x", ".next/a": "y"])
        defer { tree.remove() }
        try tree.setAllMTimes(to: oldDate)
        let failing = FakeRunner { _, _ in
            CommandResult(exitCode: 128, stdout: "", stderr: "fatal: unable to read index.lock")
        }
        let cleaner = CacheCleaner(git: GitClient(runner: failing), activity: ActivityChecker())
        let report = cleaner.run(projects: [project(tree.root)], settings: settings(), dryRun: false)
        #expect(exists(tree.url(".next/a")))
        #expect(!report.errors.isEmpty)
    }

    @Test func missingGitBinarySkipsTheFolder() throws {
        let tree = try TempTree(["src/index.ts": "x", ".next/a": "y"])
        defer { tree.remove() }
        try tree.setAllMTimes(to: oldDate)
        let missing = FakeRunner { _, _ in throw CommandRunnerError.commandNotFound("/usr/bin/git") }
        let cleaner = CacheCleaner(git: GitClient(runner: missing), activity: ActivityChecker())
        let report = cleaner.run(projects: [project(tree.root)], settings: settings(), dryRun: false)
        #expect(exists(tree.url(".next/a")))
        #expect(!report.errors.isEmpty)
    }

    @Test func notARepositoryIsNotAnError() throws {
        let tree = try TempTree(["src/index.ts": "x", ".next/a": "y"])
        defer { tree.remove() }
        try tree.setAllMTimes(to: oldDate)
        let notRepo = FakeRunner { _, _ in
            CommandResult(exitCode: 128, stdout: "", stderr: "fatal: not a git repository (or any of the parent directories): .git")
        }
        let cleaner = CacheCleaner(git: GitClient(runner: notRepo), activity: ActivityChecker())
        let report = cleaner.run(projects: [project(tree.root)], settings: settings(), dryRun: false)
        #expect(!exists(tree.url(".next")))
        #expect(report.errors.isEmpty)
    }

    @Test func projectThatBecomesActiveAfterPlanningIsNotCleaned() throws {
        let tree = try TempTree(["src/index.ts": "x", ".next/a": "y"])
        defer { tree.remove() }
        try tree.setAllMTimes(to: oldDate)
        let root = tree.root
        let cleaner = CacheCleaner(
            git: GitClient(runner: GitFixture.runner), activity: ActivityChecker(),
            beforeRemoval: { _ in
                try? Data("edit".utf8).write(to: root.appendingPathComponent("src/index.ts"))
            })

        let report = cleaner.run(projects: [project(root)], settings: settings(), dryRun: false)

        #expect(exists(tree.url(".next/a")))
        #expect(report.cleared.isEmpty)
        #expect(report.skipped.first?.skip == .recentlyActive)
    }

    @Test func folderThatBecomesTrackedAfterPlanningIsNotCleaned() throws {
        let tree = try TempTree(["src/index.ts": "x", ".next/a": "y"])
        defer { tree.remove() }
        try GitFixture.initRepo(tree.root)  // .next committed too; untrack it, then re-add after planning
        try GitFixture.git(["rm", "-r", "-q", "--cached", ".next"], in: tree.root)
        try GitFixture.git(["commit", "-q", "-m", "untrack"], in: tree.root)
        try tree.setAllMTimes(to: oldDate)
        let root = tree.root
        let cleaner = CacheCleaner(
            git: GitClient(runner: GitFixture.runner), activity: ActivityChecker(),
            beforeRemoval: { _ in _ = try? GitFixture.git(["add", "-f", ".next/a"], in: root) })

        let report = cleaner.run(projects: [project(root)], settings: settings(), dryRun: false)

        #expect(exists(tree.url(".next/a")))
        #expect(report.skipped.first?.skip == .trackedInGit)
    }

    @Test func folderReplacedBySymlinkAfterPlanningIsNotFollowed() throws {
        let tree = try TempTree(["proj/src/index.ts": "x", "proj/.next/a": "y", "outside/keep": "k"])
        defer { tree.remove() }
        try tree.setAllMTimes(to: oldDate)
        let next = tree.url("proj/.next")
        let outside = tree.url("outside")
        let cleaner = CacheCleaner(
            git: GitClient(runner: GitFixture.runner), activity: ActivityChecker(),
            beforeRemoval: { _ in
                try? FileManager.default.removeItem(at: next)
                try? FileManager.default.createSymbolicLink(at: next, withDestinationURL: outside)
            })

        let report = cleaner.run(projects: [project(tree.url("proj"))], settings: settings(), dryRun: false)

        #expect(exists(tree.url("outside/keep")))
        #expect(report.cleared.isEmpty)
        #expect(report.skipped.first?.skip == .pathChanged)
    }
}

extension CacheCleanerTests {
    @Test func cacheFolderThatIsItselfARepositoryIsNeverRemoved() throws {
        let tree = try TempTree(["src/index.ts": "x", ".next/page.js": "y", ".next/sub/deep.js": "z"])
        defer { tree.remove() }
        try GitFixture.initRepo(tree.url(".next"))
        try tree.setAllMTimes(to: Date(timeIntervalSinceNow: -30 * 24 * 3600))

        let report = CacheCleaner(git: GitClient(runner: GitFixture.runner), activity: ActivityChecker())
            .run(projects: [Project(root: tree.root, parentRoot: nil, packageManager: .npm, nodeModules: nil)],
                 settings: Settings.defaults(home: tree.root), dryRun: false)

        #expect(FileManager.default.fileExists(atPath: tree.url(".next/page.js").path))
        #expect(FileManager.default.fileExists(atPath: tree.url(".next/.git").path))
        #expect(report.skipped.first?.skip == .containsRepository)
        #expect(report.cleared.isEmpty)
    }

    @Test func repositoryNestedDeeperInsideACacheFolderIsNeverRemoved() throws {
        let tree = try TempTree(["src/index.ts": "x", "node_modules/.cache/clone/a.js": "y"])
        defer { tree.remove() }
        try GitFixture.initRepo(tree.url("node_modules/.cache/clone"))
        // A gitfile (as submodules and worktrees use) counts too.
        try tree.add([".vite/sub/.git": "gitdir: ../elsewhere\n"])
        try tree.setAllMTimes(to: Date(timeIntervalSinceNow: -30 * 24 * 3600))

        let report = CacheCleaner(git: GitClient(runner: GitFixture.runner), activity: ActivityChecker())
            .run(projects: [Project(root: tree.root, parentRoot: nil, packageManager: .npm, nodeModules: nil)],
                 settings: Settings.defaults(home: tree.root), dryRun: false)

        #expect(FileManager.default.fileExists(atPath: tree.url("node_modules/.cache/clone/a.js").path))
        #expect(FileManager.default.fileExists(atPath: tree.url(".vite/sub/.git").path))
        #expect(report.cleared.isEmpty)
        #expect(Set(report.skipped.compactMap(\.skip)) == [.containsRepository])
    }

    @Test func cacheFolderTrackedByANestedInnerRepositoryIsNeverRemoved() throws {
        let tree = try TempTree(["proj/src/index.ts": "x", "proj/pkg/.cache/keep.txt": "k", "proj/pkg/lib.js": "l"])
        defer { tree.remove() }
        // The project is not in any repository; an independent repo lives in proj/pkg and tracks .cache.
        try GitFixture.initRepo(tree.url("proj/pkg"))
        try tree.setAllMTimes(to: Date(timeIntervalSinceNow: -30 * 24 * 3600))
        var s = Settings.defaults(home: tree.root)
        s.cacheFolders = [CacheFolderSetting(relativePath: "pkg/.cache", enabled: true, isBuiltIn: false)]

        let report = CacheCleaner(git: GitClient(runner: GitFixture.runner), activity: ActivityChecker())
            .run(projects: [Project(root: tree.url("proj"), parentRoot: nil, packageManager: .npm, nodeModules: nil)],
                 settings: s, dryRun: false)

        #expect(FileManager.default.fileExists(atPath: tree.url("proj/pkg/.cache/keep.txt").path))
        #expect(report.skipped.first?.skip == .trackedInGit)
        #expect(report.cleared.isEmpty)
    }

    @Test func danglingGitFileIsAnErrorNotAnAbsentRepository() throws {
        let tree = try TempTree(["src/index.ts": "x", ".next/a": "y", ".git": "gitdir: /nonexistent/moved/repo\n"])
        defer { tree.remove() }
        try tree.setAllMTimes(to: Date(timeIntervalSinceNow: -30 * 24 * 3600))

        let report = CacheCleaner(git: GitClient(runner: GitFixture.runner), activity: ActivityChecker())
            .run(projects: [Project(root: tree.root, parentRoot: nil, packageManager: .npm, nodeModules: nil)],
                 settings: Settings.defaults(home: tree.root), dryRun: false)

        #expect(FileManager.default.fileExists(atPath: tree.url(".next/a").path))
        #expect(report.cleared.isEmpty)
        #expect(report.skipped.first?.skip == .gitUnavailable)
        #expect(!report.errors.isEmpty)
    }

    @Test(arguments: [".GIT", ".Git", "NODE_MODULES", "Node_Modules"])
    func caseVariantsOfProtectedNamesAreNeverDeleted(name: String) throws {
        let tree = try TempTree(["src/index.ts": "x", "node_modules/pkg/i.js": "z"])
        defer { tree.remove() }
        try GitFixture.git(["init", "-q", "-b", "main"], in: tree.root)
        try tree.setAllMTimes(to: Date(timeIntervalSinceNow: -30 * 24 * 3600))
        var s = Settings.defaults(home: tree.root)
        s.cacheFolders = [CacheFolderSetting(relativePath: name, enabled: true, isBuiltIn: false)]

        let report = CacheCleaner(git: GitClient(runner: GitFixture.runner), activity: ActivityChecker())
            .run(projects: [Project(root: tree.root, parentRoot: nil, packageManager: .npm, nodeModules: nil)],
                 settings: s, dryRun: false)

        #expect(report.cleared.isEmpty)
        #expect(FileManager.default.fileExists(atPath: tree.url(".git").path))
        #expect(FileManager.default.fileExists(atPath: tree.url("node_modules/pkg/i.js").path))
    }
}

/// Runs a closure instead of a real command.
struct FakeRunner: CommandRunner {
    let handler: @Sendable (String, [String]) throws -> CommandResult

    init(_ handler: @escaping @Sendable (String, [String]) throws -> CommandResult) {
        self.handler = handler
    }

    func run(_ command: String, _ args: [String], in directory: URL?) throws -> CommandResult {
        try handler(command, args)
    }
}
