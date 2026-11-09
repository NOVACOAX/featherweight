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
        #expect(history.first?.summary == "Shared duplicates in 1 projects")
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
        #expect(saved.skipped[0].hasSuffix("/.output: notEnabled"))
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

        let insideBody = f.runner.withLock(onWaiting: nil) { other.tryLock() }

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
}
