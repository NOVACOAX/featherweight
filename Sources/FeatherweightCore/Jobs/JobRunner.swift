import CoreServices
import Foundation

/// Runs dedupe and clean jobs against the projects named in the saved settings, with locking,
/// history, and refreshed `stats.json` / `projects.json`.
///
/// Every method blocks the calling thread (the heavy work runs at background QoS), so callers
/// run them off the main thread. Settings are re-read at the start of each run.
public final class JobRunner: @unchecked Sendable {
    private let paths: AppPaths
    private let runner: CommandRunner
    private let history: HistoryStore

    public init(paths: AppPaths, runner: CommandRunner = ProcessCommandRunner()) {
        self.paths = paths
        self.runner = runner
        history = HistoryStore(url: paths.history)
    }

    // MARK: Jobs

    /// Shares duplicate files between projects. A dry run takes no lock and records nothing.
    /// Otherwise the run waits for the job lock (calling `onWaiting` first if it is held),
    /// appends a `RunRecord` and refreshes savings and project summaries.
    public func dedupe(
        trigger: JobTrigger, only: [URL]? = nil, dryRun: Bool, onWaiting: (() -> Void)? = nil
    ) -> (DedupeReport, RunRecord?) {
        if dryRun {
            return (runDedupe(only: only, dryRun: true).report, nil)
        }
        return withLock(onWaiting: onWaiting) {
            let startedAt = Date()
            var (report, context) = runDedupe(only: only, dryRun: false)
            let record = RunRecord(
                id: UUID(), kind: .dedupe, trigger: trigger, startedAt: startedAt,
                finishedAt: Date(), bytesFreed: report.bytesFreed,
                summary: "Shared duplicates in \(report.perProject.count) projects",
                projects: report.perProject.keys.sorted(), skipped: [], errors: report.errors,
                lastFSEventID: FSEventsGetCurrentEventId())
            if let failure = finish(record, context) { report.errors.append(failure) }
            return (report, record)
        }
    }

    /// Clears cache folders. Locking, history and refreshes behave as for `dedupe`.
    public func clean(
        trigger: JobTrigger, only: [URL]? = nil, dryRun: Bool, onWaiting: (() -> Void)? = nil
    ) -> (CleanReport, RunRecord?) {
        if dryRun {
            return (runClean(only: only, dryRun: true).report, nil)
        }
        return withLock(onWaiting: onWaiting) {
            let startedAt = Date()
            var (report, context) = runClean(only: only, dryRun: false)
            let cleared = Set(report.cleared.map(\.projectRoot))
            let record = RunRecord(
                id: UUID(), kind: .clean, trigger: trigger, startedAt: startedAt,
                finishedAt: Date(), bytesFreed: report.bytesFreed,
                summary: "Cleared caches in \(cleared.count) projects, \(report.skipped.count) skipped",
                projects: cleared.sorted(),
                skipped: report.skipped.map { "\($0.folder): \($0.skip?.rawValue ?? "skipped")" },
                errors: report.errors, lastFSEventID: FSEventsGetCurrentEventId())
            var clearedBytes: [String: Int64] = [:]
            for candidate in report.cleared { clearedBytes[candidate.projectRoot, default: 0] += candidate.allocatedBytes }
            if let failure = finish(record, context, clearedBytes: clearedBytes) { report.errors.append(failure) }
            return (report, record)
        }
    }

    /// Holds the job lock while `body` runs, calling `onWaiting` first if another process holds it.
    public func withLock<T>(onWaiting: (() -> Void)?, _ body: () throws -> T) rethrows -> T {
        try? paths.ensureExists()
        let lock = JobLock(url: paths.jobLock)
        if !lock.tryLock() {
            onWaiting?()
            lock.lock()
        }
        defer { lock.unlock() }
        return try body()
    }

    // MARK: Refreshing derived state

    /// Re-measures shared bytes and writes `stats.json`.
    @discardableResult
    public func refreshSavings() -> SavingsSnapshot {
        let context = loadContext()
        return writeSavings(context.allProjects)
    }

    /// Rebuilds and writes `projects.json`.
    @discardableResult
    public func refreshSummaries() -> [ProjectSummary] {
        let context = loadContext()
        return writeSummaries(context, savings: readSavings() ?? SavingsSnapshot(measuredAt: Date()), clearedBytes: [:])
    }

    // MARK: Internals

    private struct Context {
        let settings: Settings
        /// Every project under the configured folders.
        let allProjects: [Project]
        /// The projects this run works on (`only`, or all of them).
        let runProjects: [Project]
    }

    private func loadContext(only: [URL]? = nil) -> Context {
        let settings = SettingsStore(paths: paths).load()
        // Cache folder names without a "/" are skipped while scanning, so their contents are not
        // mistaken for projects.
        let excluded = Set(settings.cacheFolders.map(\.relativePath).filter { !$0.contains("/") })
        let all = ProjectScanner(excludedDirectoryNames: excluded)
            .scan(folders: settings.projectFolders.map { URL(fileURLWithPath: $0, isDirectory: true) })
        var run = all
        if let only {
            let wanted = Set(only.map(Self.normalized))
            run = all.filter { wanted.contains(Self.normalized($0.root)) }
        }
        return Context(settings: settings, allProjects: all, runProjects: run)
    }

    private static func normalized(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func runDedupe(only: [URL]?, dryRun: Bool) -> (report: DedupeReport, context: Context) {
        let context = loadContext(only: only)
        try? paths.ensureExists()
        do {
            let cache = try HashCache(url: paths.hashCache)
            let report = Deduper(hashCache: cache).run(projects: context.runProjects, dryRun: dryRun)
            return (report, context)
        } catch {
            return (DedupeReport(errors: ["hash cache: \(error)"]), context)
        }
    }

    private func runClean(only: [URL]?, dryRun: Bool) -> (report: CleanReport, context: Context) {
        let context = loadContext(only: only)
        let cleaner = CacheCleaner(git: GitClient(runner: runner), activity: ActivityChecker())
        let report = cleaner.run(projects: context.runProjects, settings: context.settings, dryRun: dryRun)
        return (report, context)
    }

    /// Appends the record, then refreshes savings and summaries. Returns a message if the
    /// history file could not be written.
    private func finish(_ record: RunRecord, _ context: Context, clearedBytes: [String: Int64] = [:]) -> String? {
        var failure: String?
        do {
            try history.append(record)
        } catch {
            failure = "history: \(error.localizedDescription)"
        }
        let savings = writeSavings(context.allProjects)
        writeSummaries(context, savings: savings, clearedBytes: clearedBytes)
        return failure
    }

    private func writeSavings(_ projects: [Project]) -> SavingsSnapshot {
        let snapshot = SavingsMeter().measure(projects: projects, now: Date())
        write(snapshot, to: paths.stats)
        return snapshot
    }

    private func readSavings() -> SavingsSnapshot? {
        guard let data = try? Data(contentsOf: paths.stats) else { return nil }
        return try? JSONDecoder().decode(SavingsSnapshot.self, from: data)
    }

    @discardableResult
    private func writeSummaries(
        _ context: Context, savings: SavingsSnapshot, clearedBytes: [String: Int64]
    ) -> [ProjectSummary] {
        let projects = context.allProjects
        let plan = CacheCleaner(git: GitClient(runner: runner), activity: ActivityChecker())
            .plan(projects: projects, settings: context.settings)
        let candidatesByRoot = Dictionary(grouping: plan, by: \.projectRoot)
        let measured = BackgroundWork.run { Self.measure(projects) }
        let git = GitClient(runner: runner)
        let lastClean = history.lastRun(of: .clean)

        let summaries = projects.enumerated().map { index, project in
            let root = project.root.path
            let candidates = candidatesByRoot[root] ?? []
            let repo = git.repoRoot(for: project.root)
            let cleared = lastClean?.projects.contains(root) == true
            return ProjectSummary(
                id: root,
                name: project.root.lastPathComponent,
                parentRoot: project.parentRoot?.path,
                packageManager: project.packageManager,
                nodeModulesBytes: measured.logicalBytes[index],
                sharedBytes: savings.perProject[root] ?? 0,
                cacheBytes: candidates.reduce(0) { $0 + $1.allocatedBytes },
                lastActive: measured.lastActive[index],
                status: ProjectSummary.status(
                    packageManager: project.packageManager, candidates: candidates,
                    clearedByLastClean: cleared, clearedBytes: clearedBytes[root]),
                gitBranch: repo.flatMap(git.currentBranch),
                upstream: repo.flatMap(git.upstream),
                remoteURL: repo.flatMap { git.remoteURL($0, remote: "origin") })
        }
        write(summaries, to: paths.projects)
        return summaries
    }

    /// Logical `node_modules` size and newest source change for each project, by index.
    private static func measure(_ projects: [Project]) -> (logicalBytes: [Int64], lastActive: [Date?]) {
        var logical = [Int64](repeating: 0, count: projects.count)
        NodeModulesFiles.forEach(in: projects, onError: { _ in }) { file in
            logical[file.project] += file.info.size
        }
        let activity = ActivityChecker()
        return (logical, projects.map { activity.lastSourceChange(root: $0.root) })
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? paths.ensureExists()
        try? data.write(to: url, options: .atomic)
    }
}
