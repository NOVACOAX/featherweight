import Foundation
import Testing

@testable import FeatherweightCore

/// A temp state directory plus two fake projects that share a 64 KiB file, with `Settings` saved
/// so the runner scans them. Never touches the real home or Application Support directory.
private struct RunnerFixture {
    let tree: TempTree
    let paths: AppPaths
    let runner: JobRunner

    init(extraFiles: [String: String] = [:]) throws {
        var files: [String: String] = [:]
        for (i, name) in ["a", "b"].enumerated() {
            files["projects/\(name)/package.json"] = "{}"
            files["projects/\(name)/package-lock.json"] = "{}"
            files["projects/\(name)/node_modules/react/index.js"] = DedupeFixture.payload
            files["projects/\(name)/node_modules/\(name)-only/unique.js"] =
                String(repeating: name, count: 100 * (i + 1))
        }
        files.merge(extraFiles) { $1 }
        tree = try TempTree(files)
        try tree.setAllMTimes(to: Date().addingTimeInterval(-30 * 86_400))
        paths = AppPaths(
            base: tree.url("state"), launchAgentsDir: tree.url("LaunchAgents"), home: tree.root)
        var settings = Settings.defaults(home: tree.root)
        settings.projectFolders = [tree.url("projects").path]
        try SettingsStore(paths: paths).save(settings)
        runner = JobRunner(paths: paths)
    }

    func projectURL(_ name: String) -> URL {
        URL(fileURLWithPath: tree.url("projects/\(name)").path, isDirectory: true)
    }

    func readJSON<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }
}

@Suite struct JobRunnerTests {
    @Test func runnerDedupeRecordsHistoryAndStats() throws {
        let f = try RunnerFixture()
        defer { f.tree.remove() }

        let (report, record) = f.runner.dedupe(trigger: .manualCLI, dryRun: false)

        #expect(report.bytesFreed > 0)
        let history = HistoryStore(url: f.paths.history).all()
        #expect(history.count == 1)
        #expect(history.first == record)
        #expect(history.first?.kind == .dedupe)
        #expect(history.first?.trigger == .manualCLI)
        #expect((history.first?.bytesFreed ?? 0) > 0)
        #expect(history.first?.summary == "Shared duplicates in 1 project")
        #expect((history.first?.lastFSEventID ?? 0) > 0)

        let stats = try f.readJSON(SavingsSnapshot.self, f.paths.stats)
        #expect(stats.sharedBytes > 0)
        let summaries = try f.readJSON([ProjectSummary].self, f.paths.projects)
        #expect(summaries.count == 2)
        #expect(summaries.map(\.name) == ["a", "b"])
        #expect(summaries.allSatisfy { $0.nodeModulesBytes >= 65_536 })
        #expect(summaries.map(\.sharedBytes).reduce(0, +) > 0)
        #expect(summaries.allSatisfy { $0.packageManager == .npm && $0.parentRoot == nil })
    }

    @Test func runnerDryRunRecordsNothing() throws {
        let f = try RunnerFixture(extraFiles: ["projects/a/.next/cache.bin": "xxxx"])
        try f.tree.setAllMTimes(to: Date().addingTimeInterval(-30 * 86_400))
        defer { f.tree.remove() }

        let (dedupe, dedupeRecord) = f.runner.dedupe(trigger: .manualApp, dryRun: true)
        let (clean, cleanRecord) = f.runner.clean(trigger: .manualApp, dryRun: true)

        #expect(dedupe.bytesFreed > 0)
        #expect(clean.cleared.count == 1)
        #expect(dedupeRecord == nil && cleanRecord == nil)
        #expect(!FileManager.default.fileExists(atPath: f.paths.history.path))
        #expect(!FileManager.default.fileExists(atPath: f.paths.stats.path))
        #expect(!FileManager.default.fileExists(atPath: f.paths.projects.path))
        #expect(FileManager.default.fileExists(atPath: f.tree.url("projects/a/.next/cache.bin").path))
    }

    @Test func dryRunTakesNoLock() throws {
        let f = try RunnerFixture()
        defer { f.tree.remove() }
        let held = JobLock(url: f.paths.jobLock)
        try f.paths.ensureExists()
        #expect(held.tryLock())
        defer { held.unlock() }

        let (_, record) = f.runner.dedupe(trigger: .manualCLI, dryRun: true)
        #expect(record == nil)
    }

    @Test func runnerCleanRecordsClearedProjectsAndSkips() throws {
        let f = try RunnerFixture(extraFiles: [
            "projects/a/.next/cache.bin": String(repeating: "x", count: 100_000),
            "projects/b/.next/cache.bin": "y",
            "projects/b/.output/server.js": "z",
        ])
        try f.tree.setAllMTimes(to: Date().addingTimeInterval(-30 * 86_400))
        defer { f.tree.remove() }

        let (report, record) = f.runner.clean(trigger: .scheduled, dryRun: false)

        #expect(report.cleared.count == 2)
        #expect(!FileManager.default.fileExists(atPath: f.tree.url("projects/a/.next").path))
        #expect(FileManager.default.fileExists(atPath: f.tree.url("projects/b/.output").path))
        let saved = try #require(HistoryStore(url: f.paths.history).all().first)
        #expect(saved == record)
        #expect(saved.kind == .clean)
        #expect(saved.bytesFreed == report.bytesFreed)
        #expect(saved.summary == "Cleared caches in 2 projects, 1 skipped")
        #expect(saved.projects == [f.projectURL("a").path, f.projectURL("b").path])
        #expect(saved.skipped.count == 1)
        #expect(saved.skipped == ["b/.output: Turned off in Settings"])
        let summaries = try f.readJSON([ProjectSummary].self, f.paths.projects)
        #expect(summaries.first { $0.name == "a" }?.status.hasPrefix("Cleared") == true)
        #expect(summaries.first { $0.name == "b" }?.status.hasPrefix("Cleared") == true)
    }

    @Test func onlyRestrictsRunToListedProjects() throws {
        let f = try RunnerFixture(extraFiles: [
            "projects/a/.next/cache.bin": "x", "projects/b/.next/cache.bin": "y",
        ])
        try f.tree.setAllMTimes(to: Date().addingTimeInterval(-30 * 86_400))
        defer { f.tree.remove() }

        let (report, record) = f.runner.clean(
            trigger: .manualCLI, only: [f.projectURL("a")], dryRun: false)

        #expect(report.cleared.map(\.projectRoot) == [f.projectURL("a").path])
        #expect(record?.projects == [f.projectURL("a").path])
        #expect(!FileManager.default.fileExists(atPath: f.tree.url("projects/a/.next").path))
        #expect(FileManager.default.fileExists(atPath: f.tree.url("projects/b/.next").path))
        // Summaries still describe every project.
        #expect(try f.readJSON([ProjectSummary].self, f.paths.projects).count == 2)
    }

    @Test func cacheFolderNamesAreNotScannedAsProjects() throws {
        let f = try RunnerFixture(extraFiles: ["projects/a/.next/standalone/package.json": "{}"])
        defer { f.tree.remove() }

        _ = f.runner.refreshSummaries()

        let summaries = try f.readJSON([ProjectSummary].self, f.paths.projects)
        #expect(summaries.map(\.name) == ["a", "b"])
    }

    @Test func generatedDeployOutputIsNotScannedAsProjects() throws {
        let f = try RunnerFixture(extraFiles: [
            "projects/a/.vercel/output/functions/__nitro.func/package.json": "{}",
            "projects/a/.netlify/functions-internal/package.json": "{}",
            "projects/b/.svelte-kit/output/package.json": "{}",
            "projects/b/.wrangler/tmp/package.json": "{}",
            "projects/b/.firebase/hosting/package.json": "{}",
            "projects/b/.expo/web/package.json": "{}",
        ])
        defer { f.tree.remove() }

        _ = f.runner.refreshSummaries()

        let summaries = try f.readJSON([ProjectSummary].self, f.paths.projects)
        #expect(summaries.map(\.name) == ["a", "b"])
    }

    @Test func summariesNeverStoreRemoteCredentialsAndRecordTheSkipReason() throws {
        let f = try RunnerFixture()
        defer { f.tree.remove() }
        let a = f.projectURL("a")
        try GitFixture.initRepo(a)
        try GitFixture.git(["remote", "add", "origin", "https://user:ghp_secrettoken@github.com/org/repo.git"], in: a)
        // Recently active, so the cleaner would skip its caches.
        try FileManager.default.createDirectory(at: a.appendingPathComponent(".next"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: a.appendingPathComponent("src.js"))

        _ = f.runner.refreshSummaries()

        let raw = try String(contentsOf: f.paths.projects, encoding: .utf8)
        #expect(!raw.contains("ghp_secrettoken"))
        #expect(!raw.contains("user:"))
        let summary = try #require(f.readJSON([ProjectSummary].self, f.paths.projects).first { $0.name == "a" })
        #expect(summary.remoteURL == "https://github.com/org/repo.git")
        #expect(summary.skipReason == .recentlyActive)
        #expect(summary.status == "Skipped: active")
    }

    @Test func finishingAJobWalksNodeModulesOnce() throws {
        let f = try RunnerFixture()
        defer { f.tree.remove() }
        let folder = f.projectURL("a").appendingPathComponent("node_modules").path
        let before = NodeModulesFiles.walks(of: folder)

        _ = f.runner.dedupe(trigger: .manualCLI, dryRun: false)

        // One walk to find duplicates, one to measure savings and sizes together.
        #expect(NodeModulesFiles.walks(of: folder) - before == 2)
        let summaries = try f.readJSON([ProjectSummary].self, f.paths.projects)
        #expect(summaries.allSatisfy { $0.nodeModulesBytes >= 65_536 })
        let stats = try f.readJSON(SavingsSnapshot.self, f.paths.stats)
        #expect(stats.sharedBytes > 0)
        #expect(summaries.map(\.sharedBytes).reduce(0, +) == stats.sharedBytes)
    }

    @Test func aScopedJobWalksOnlyItsOwnProjects() throws {
        let f = try RunnerFixture()
        defer { f.tree.remove() }
        // A full run measures every project and keeps each one's tally.
        _ = f.runner.dedupe(trigger: .scheduled, dryRun: false)
        let fullStats = try f.readJSON(SavingsSnapshot.self, f.paths.stats)
        let fullSummaries = try f.readJSON([ProjectSummary].self, f.paths.projects)
        #expect(fullStats.sharedBytes > 0)
        let a = f.projectURL("a").appendingPathComponent("node_modules").path
        let b = f.projectURL("b").appendingPathComponent("node_modules").path
        let (walksA, walksB) = (NodeModulesFiles.walks(of: a), NodeModulesFiles.walks(of: b))

        _ = f.runner.dedupe(trigger: .afterInstall, only: [f.projectURL("a")], dryRun: false)

        #expect(NodeModulesFiles.walks(of: b) == walksB)
        #expect(NodeModulesFiles.walks(of: a) - walksA == 2)
        // The figures are exactly what a full measurement gives, credit split included.
        let stats = try f.readJSON(SavingsSnapshot.self, f.paths.stats)
        #expect(stats.sharedBytes == fullStats.sharedBytes)
        #expect(stats.perProject == fullStats.perProject)
        let summaries = try f.readJSON([ProjectSummary].self, f.paths.projects)
        #expect(summaries.map(\.nodeModulesBytes) == fullSummaries.map(\.nodeModulesBytes))
        let direct = SavingsMeter().measure(projects: [
            Project(root: f.projectURL("a"), parentRoot: nil, packageManager: .npm, nodeModules: URL(fileURLWithPath: a)),
            Project(root: f.projectURL("b"), parentRoot: nil, packageManager: .npm, nodeModules: URL(fileURLWithPath: b)),
        ], now: Date())
        #expect(stats.sharedBytes == direct.sharedBytes)
        #expect(stats.perProject == direct.perProject)
    }

    @Test func aScopedJobAlsoMeasuresProjectsItHasNotSeen() throws {
        let f = try RunnerFixture()
        defer { f.tree.remove() }
        _ = f.runner.dedupe(trigger: .scheduled, dryRun: false)
        try f.tree.add([
            "projects/c/package.json": "{}",
            "projects/c/package-lock.json": "{}",
            "projects/c/node_modules/c-only/index.js": String(repeating: "c", count: 4_000),
        ])
        try f.tree.setAllMTimes(to: Date().addingTimeInterval(-30 * 86_400))
        let c = f.projectURL("c").appendingPathComponent("node_modules").path
        let b = f.projectURL("b").appendingPathComponent("node_modules").path
        let walksB = NodeModulesFiles.walks(of: b)

        _ = f.runner.dedupe(trigger: .afterInstall, only: [f.projectURL("a")], dryRun: false)

        #expect(NodeModulesFiles.walks(of: c) == 1)
        #expect(NodeModulesFiles.walks(of: b) == walksB)
        let summaries = try f.readJSON([ProjectSummary].self, f.paths.projects)
        #expect(summaries.first { $0.name == "c" }?.nodeModulesBytes == 4_000)
    }

    @Test func nonDryRunWaitsForTheLockAndReportsWaiting() throws {
        let f = try RunnerFixture()
        defer { f.tree.remove() }
        try f.paths.ensureExists()
        let held = JobLock(url: f.paths.jobLock)
        #expect(held.tryLock())

        let waiting = Locked(false)
        let result = Locked<RunRecord??>(nil)
        let done = DispatchSemaphore(value: 0)
        Thread {
            result.value = .some(f.runner.dedupe(trigger: .manualCLI, dryRun: false, onWaiting: {
                waiting.value = true
            }).1)
            done.signal()
        }.start()

        let deadline = Date().addingTimeInterval(5)
        while !waiting.value && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        #expect(waiting.value)
        #expect(result.value == nil)  // still blocked
        held.unlock()
        #expect(done.wait(timeout: .now() + 30) == .success)
        #expect(result.value??.kind == .dedupe)
    }

    @Test func withLockHoldsTheLockForTheBody() throws {
        let f = try RunnerFixture()
        defer { f.tree.remove() }
        let other = JobLock(url: f.paths.jobLock)

        let insideBody = try f.runner.withLock(onWaiting: nil) { other.tryLock() }

        #expect(!insideBody)
        #expect(other.tryLock())  // released after the body
        other.unlock()
    }

    @Test func refreshSavingsWritesStats() throws {
        let f = try RunnerFixture()
        defer { f.tree.remove() }

        let snapshot = f.runner.refreshSavings()

        #expect(snapshot.sharedBytes == 0)
        #expect(try f.readJSON(SavingsSnapshot.self, f.paths.stats) == snapshot)
    }

    @Test func cleanSummaryUsesSingularForOneProject() throws {
        let f = try RunnerFixture(extraFiles: ["projects/a/.next/cache.bin": "x"])
        try f.tree.setAllMTimes(to: Date().addingTimeInterval(-30 * 86_400))
        defer { f.tree.remove() }

        let (_, record) = f.runner.clean(trigger: .manualCLI, dryRun: false)

        #expect(record?.summary == "Cleared caches in 1 project, 0 skipped")
    }

    @Test func skippedEntriesAreHumanReadableAndUseConfiguredWindow() throws {
        let f = try RunnerFixture(extraFiles: ["projects/a/.next/cache.bin": "x"])
        defer { f.tree.remove() }
        try f.tree.setMTime("projects/a/package.json", to: Date())  // project a is active
        var settings = SettingsStore(paths: f.paths).load()
        settings.activityWindowHours = 6
        try SettingsStore(paths: f.paths).save(settings)

        let (_, record) = f.runner.clean(trigger: .manualCLI, dryRun: false)

        #expect(record?.skipped == ["a/.next: Active in the last 6 hours"])
    }

    @Test func unavailableLockMeansTheJobDoesNotRun() throws {
        let f = try RunnerFixture(extraFiles: ["projects/a/.next/cache.bin": "x"])
        try f.tree.setAllMTimes(to: Date().addingTimeInterval(-30 * 86_400))
        defer { f.tree.remove() }
        try FileManager.default.createDirectory(at: f.paths.jobLock, withIntermediateDirectories: true)
        let waited = Locked(false)
        let ran = Locked(false)

        #expect(throws: (any Error).self) {
            try f.runner.withLock(onWaiting: { waited.value = true }) { ran.value = true }
        }
        let (dedupe, dedupeRecord) = f.runner.dedupe(trigger: .manualCLI, dryRun: false)
        let (clean, cleanRecord) = f.runner.clean(trigger: .manualCLI, dryRun: false)

        #expect(!ran.value && !waited.value)
        #expect(dedupeRecord == nil && cleanRecord == nil)
        #expect(dedupe.bytesFreed == 0 && dedupe.filesReplaced == 0)
        #expect(clean.cleared.isEmpty && clean.bytesFreed == 0)
        #expect(dedupe.errors.count == 1 && clean.errors.count == 1)
        #expect(FileManager.default.fileExists(atPath: f.tree.url("projects/a/.next/cache.bin").path))
        #expect(!FileManager.default.fileExists(atPath: f.paths.history.path))
        let info = try CloneFS.info(at: f.tree.url("projects/b/node_modules/react/index.js"))
        #expect(!info.sharesAllBlocks)
    }

    @Test func derivedStateWriteFailuresAreReported() throws {
        let f = try RunnerFixture()
        defer { f.tree.remove() }
        try FileManager.default.createDirectory(at: f.paths.stats, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: f.paths.projects, withIntermediateDirectories: true)

        let (report, record) = f.runner.dedupe(trigger: .manualCLI, dryRun: false)

        #expect(record != nil)  // the job itself ran and was recorded
        #expect(report.bytesFreed > 0)
        #expect(report.errors.contains { $0.hasPrefix("stats.json:") })
        #expect(report.errors.contains { $0.hasPrefix("projects.json:") })
        #expect(HistoryStore(url: f.paths.history).all().count == 1)
    }
}
