import Foundation
import Testing

@testable import FeatherweightCore

/// `JobRunner.convert` and `revert`: the job lock, history records and backup bookkeeping around
/// `PnpmConverter`. Package-manager commands go to a fake runner; nothing touches the real home.
private struct ConversionFixture {
    let tree: TempTree
    let paths: AppPaths
    let jobs: JobRunner
    let commands = FakeCommandRunner()
    let lock = #"{ "name": "a", "lockfileVersion": 3, "packages": { "": { "name": "a" } } }"#

    init(mtime: Date = Date().addingTimeInterval(-30 * 86_400)) throws {
        tree = try TempTree([
            "projects/a/package.json": #"{ "name": "a", "scripts": { "test": "npm run lint" } }"#,
            "projects/a/package-lock.json": lock,
            "projects/a/node_modules/left-pad/index.js": "module.exports = 1\n",
        ])
        try tree.setAllMTimes(to: mtime)
        paths = AppPaths(base: tree.url("state"), launchAgentsDir: tree.url("LaunchAgents"), home: tree.root)
        var settings = Settings.defaults(home: tree.root)
        settings.projectFolders = [tree.url("projects").path]
        try SettingsStore(paths: paths).save(settings)
        jobs = JobRunner(paths: paths)

        commands.script("pnpm --version", stdout: "10.33.2\n")
        commands.script("pnpm import") { dir in
            try Data("lockfileVersion: '9.0'\n".utf8).write(to: URL(fileURLWithPath: dir!.path + "/pnpm-lock.yaml"))
        }
        commands.script("pnpm install --frozen-lockfile") { dir in
            try FileManager.default.createDirectory(
                atPath: dir!.path + "/node_modules/.pnpm", withIntermediateDirectories: true)
        }
    }

    var root: URL { URL(fileURLWithPath: tree.url("projects/a").path, isDirectory: true) }

    var project: Project {
        Project(root: root, parentRoot: nil, packageManager: .npm, nodeModules: root.appendingPathComponent("node_modules"))
    }

    var history: [RunRecord] { HistoryStore(url: paths.history).all() }

    func file(_ name: String) -> String { root.path + "/" + name }
}

@Suite struct ConversionJobTests {
    @Test func convertRecordsHistoryAndRefreshesSummaries() throws {
        let f = try ConversionFixture()
        defer { f.tree.remove() }

        let result = try f.jobs.convert(f.project, runBuildCheck: false, using: f.commands) { _ in }

        #expect(result.changes.contains { $0.relativePath == "package-lock.json" && $0.kind == .deleted })
        // The real config rewriter ran.
        #expect(try String(contentsOfFile: f.file("package.json"), encoding: .utf8).contains("pnpm run lint"))
        let record = try #require(f.history.first)
        #expect(f.history.count == 1)
        #expect(record.kind == .convert)
        #expect(record.trigger == .manualApp)
        #expect(record.summary == "Converted a to pnpm")
        #expect(record.projects == [f.root.path])
        #expect(record.errors.isEmpty)
        #expect(record.lastFSEventID > 0)
        let summaries = try JSONDecoder().decode([ProjectSummary].self, from: Data(contentsOf: f.paths.projects))
        #expect(summaries.first { $0.name == "a" }?.packageManager == .pnpm)
        #expect(ConversionBackup.latest(for: f.root, paths: f.paths)?.id == result.backupID)
    }

    @Test func failedConvertRecordsTheErrorAndDropsItsBackup() throws {
        let f = try ConversionFixture()
        defer { f.tree.remove() }
        f.commands.script("pnpm install --frozen-lockfile", exitCode: 1, stderr: "ERR_PNPM_FETCH_404\n")

        #expect {
            try f.jobs.convert(f.project, runBuildCheck: false, using: f.commands) { _ in }
        } throws: { error in
            (error as? ConversionFailure)?.step == .installing && (error as? ConversionFailure)?.reverted == true
        }

        let record = try #require(f.history.first)
        #expect(record.kind == .convert)
        #expect(record.bytesFreed == 0)
        #expect(record.summary == "Converting a to pnpm failed; it was put back as it was")
        #expect(record.errors.first?.contains("pnpm install --frozen-lockfile") == true)
        #expect(ConversionBackup.latest(for: f.root, paths: f.paths) == nil)
        #expect(try String(contentsOfFile: f.file("package-lock.json"), encoding: .utf8) == f.lock)
    }

    @Test func convertRefusesARecentlyActiveProject() throws {
        let f = try ConversionFixture(mtime: Date())
        defer { f.tree.remove() }

        #expect {
            try f.jobs.convert(f.project, runBuildCheck: false, using: f.commands) { _ in }
        } throws: { error in
            (error as? ConversionFailure)?.output == "Active in the last 24 hours"
        }
        #expect(f.commands.calls.isEmpty)
        #expect(f.history.isEmpty)
    }

    @Test func convertWaitsForTheJobLock() throws {
        let f = try ConversionFixture()
        defer { f.tree.remove() }
        try f.paths.ensureExists()
        let held = JobLock(url: f.paths.jobLock)
        #expect(held.tryLock())

        let waiting = Locked(false)
        let finished = Locked(false)
        let done = DispatchSemaphore(value: 0)
        Thread {
            _ = try? f.jobs.convert(
                f.project, runBuildCheck: false, using: f.commands, onWaiting: { waiting.value = true }) { _ in }
            finished.value = true
            done.signal()
        }.start()

        let deadline = Date().addingTimeInterval(5)
        while !waiting.value && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        #expect(waiting.value)
        #expect(!finished.value)
        #expect(f.commands.calls.isEmpty)
        held.unlock()
        #expect(done.wait(timeout: .now() + 30) == .success)
        #expect(f.history.first?.kind == .convert)
    }

    @Test func revertRestoresRecordsAndDropsTheBackup() throws {
        let f = try ConversionFixture()
        defer { f.tree.remove() }
        _ = try f.jobs.convert(f.project, runBuildCheck: false, using: f.commands) { _ in }
        let converted = Project(root: f.root, parentRoot: nil, packageManager: .pnpm, nodeModules: nil)

        try f.jobs.revert(converted, using: f.commands)

        #expect(try String(contentsOfFile: f.file("package-lock.json"), encoding: .utf8) == f.lock)
        #expect(!FileManager.default.fileExists(atPath: f.file("pnpm-lock.yaml")))
        #expect(f.commands.calls.last == "npm ci")
        #expect(f.history.first?.kind == .revert)
        #expect(f.history.first?.summary == "Reverted a to npm")
        #expect(ConversionBackup.latest(for: f.root, paths: f.paths) == nil)
    }

    @Test func backupKnowsWhichFilesChangedSinceTheConversion() throws {
        let f = try ConversionFixture()
        defer { f.tree.remove() }
        _ = try f.jobs.convert(f.project, runBuildCheck: false, using: f.commands) { _ in }
        let backup = try #require(ConversionBackup.latest(for: f.root, paths: f.paths))
        #expect(backup.filesChangedSinceConversion() == [])

        // Weeks later: a dependency was added and the old lockfile reappeared.
        try Data(#"{ "name": "a", "dependencies": { "left-pad": "1.3.0" } }"#.utf8).write(to: URL(fileURLWithPath: f.file("package.json")))
        try Data("{}".utf8).write(to: URL(fileURLWithPath: f.file("package-lock.json")))

        #expect(backup.filesChangedSinceConversion() == ["package-lock.json", "package.json"])
    }

    @Test func revertWithoutABackupThrows() throws {
        let f = try ConversionFixture()
        defer { f.tree.remove() }
        #expect(throws: ConversionFailure.self) { try f.jobs.revert(f.project, using: f.commands) }
        #expect(f.commands.calls.isEmpty)
    }
}

@Suite struct ConversionCommitTests {
    @Test func defaultMessages() {
        #expect(ConversionCommit.defaultMessage(from: .npm) == "Switch from npm to pnpm")
        #expect(ConversionCommit.defaultMessage(from: .yarn) == "Switch from yarn to pnpm")
    }

    @Test func pathsAreMadeRelativeToTheRepository() throws {
        let tree = try TempTree(["repo/web app /package.json": "{}"])
        defer { tree.remove() }
        let changes = ["package-lock.json", "pnpm-lock.yaml"].map {
            FileChange(relativePath: $0, kind: .modified, diff: "")
        }
        #expect(ConversionCommit.repoPaths(
            changes, projectRoot: tree.url("repo/web app "), repoRoot: tree.url("repo"))
            == ["web app /package-lock.json", "web app /pnpm-lock.yaml"])
        #expect(ConversionCommit.repoPaths(changes, projectRoot: tree.url("repo"), repoRoot: tree.url("repo"))
            == ["package-lock.json", "pnpm-lock.yaml"])
    }

    @Test func onlyPathsGitSeesAreStaged() throws {
        let tree = try TempTree([
            ".gitignore": "package-lock.json\n",
            "package.json": "{}\n",
            "notes.md": "draft\n",
        ])
        defer { tree.remove() }
        try GitFixture.initRepo(tree.root)
        // The conversion changed package.json, added pnpm-lock.yaml and deleted an ignored lockfile.
        try tree.add(["package.json": "{ \"x\": 1 }\n", "pnpm-lock.yaml": "lockfileVersion: '9.0'\n", "notes.md": "edited\n"])
        let git = GitClient(runner: GitFixture.runner)

        let changed = try git.changedPaths(["package.json", "pnpm-lock.yaml", "package-lock.json"], repoRoot: tree.root)

        #expect(changed == ["package.json", "pnpm-lock.yaml"])
    }
}
