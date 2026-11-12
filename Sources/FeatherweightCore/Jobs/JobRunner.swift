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
        do {
            return try withLock(onWaiting: onWaiting) {
                let startedAt = Date()
                var (report, context) = runDedupe(only: only, dryRun: false)
                let record = RunRecord(
                    id: UUID(), kind: .dedupe, trigger: trigger, startedAt: startedAt,
                    finishedAt: Date(), bytesFreed: report.bytesFreed,
                    summary: "Shared duplicates in \(Self.projects(report.perProject.count))",
                    projects: report.perProject.keys.sorted(), skipped: [], errors: report.errors,
                    lastFSEventID: FSEventsGetCurrentEventId())
                report.errors += finish(record, context)
                return (report, record)
            }
        } catch {
            return (DedupeReport(errors: [Self.lockFailure(error)]), nil)
        }
    }

    /// Clears cache folders. Locking, history and refreshes behave as for `dedupe`.
    public func clean(
        trigger: JobTrigger, only: [URL]? = nil, dryRun: Bool, onWaiting: (() -> Void)? = nil
    ) -> (CleanReport, RunRecord?) {
        if dryRun {
            return (runClean(only: only, dryRun: true).report, nil)
        }
        do {
            return try withLock(onWaiting: onWaiting) {
                let startedAt = Date()
                var (report, context) = runClean(only: only, dryRun: false)
                let cleared = Set(report.cleared.map(\.projectRoot))
                let hours = context.settings.activityWindowHours
                let record = RunRecord(
                    id: UUID(), kind: .clean, trigger: trigger, startedAt: startedAt,
                    finishedAt: Date(), bytesFreed: report.bytesFreed,
                    summary: "Cleared caches in \(Self.projects(cleared.count)), \(report.skipped.count) skipped",
                    projects: cleared.sorted(),
                    skipped: report.skipped.map { Self.skippedText($0, activityWindowHours: hours) },
                    errors: report.errors, lastFSEventID: FSEventsGetCurrentEventId())
                var clearedBytes: [String: Int64] = [:]
                for candidate in report.cleared {
                    clearedBytes[candidate.projectRoot, default: 0] += candidate.allocatedBytes
                }
                report.errors += finish(record, context, clearedBytes: clearedBytes)
                return (report, record)
            }
        } catch {
            return (CleanReport(errors: [Self.lockFailure(error)]), nil)
        }
    }

    /// Holds the job lock while `body` runs, calling `onWaiting` first if another process holds it.
    /// Throws, without running `body`, if the lock cannot be taken at all.
    public func withLock<T>(onWaiting: (() -> Void)?, _ body: () throws -> T) throws -> T {
        try paths.ensureExists()
        let lock = JobLock(url: paths.jobLock)
        if try !lock.tryAcquire() {
            onWaiting?()
            try lock.lock()
        }
        defer { lock.unlock() }
        return try body()
    }

    // MARK: Converting to pnpm

    /// Converts `project` to pnpm under the job lock (calling `onWaiting` first if it is held), then
    /// appends a `.convert` record and refreshes savings and summaries. Package-manager commands run
    /// through `commands` (the runner's own by default). A project that is not eligible is refused
    /// before anything changes. A failure is recorded, then rethrown as a `ConversionFailure`; when
    /// the project was put back, that attempt's backup is removed so it can't be "reverted" again.
    public func convert(
        _ project: Project, runBuildCheck: Bool, using commands: CommandRunner? = nil,
        onWaiting: (() -> Void)? = nil, progress: @Sendable (ConversionStep) -> Void
    ) throws -> ConversionResult {
        try withLock(onWaiting: onWaiting) {
            let hours = SettingsStore(paths: paths).load().activityWindowHours
            if let reason = ConversionEligibility.check(project, activity: ActivityChecker(), windowHours: hours) {
                throw ConversionFailure(
                    step: .backingUp, command: "", output: reason.message(windowHours: hours), reverted: true)
            }
            let name = project.root.lastPathComponent
            let startedAt = Date()
            let converter = PnpmConverter(runner: commands ?? runner, paths: paths, rewriter: ConfigRewriter())
            do {
                let result = try converter.convert(project, runBuildCheck: runBuildCheck, progress: progress)
                _ = finish(
                    conversionRecord(
                        .convert, startedAt: startedAt, project: project, bytesFreed: result.bytesFreed,
                        summary: "Converted \(name) to pnpm", errors: []),
                    loadContext())
                return result
            } catch let failure as ConversionFailure {
                if failure.reverted, let backup = ConversionBackup.latest(for: project.root, paths: paths),
                   backup.createdAt >= startedAt {
                    try? backup.delete(paths: paths)
                }
                let summary = failure.reverted
                    ? "Converting \(name) to pnpm failed; it was put back as it was"
                    : "Converting \(name) to pnpm failed and could not be fully undone"
                _ = finish(
                    conversionRecord(
                        .convert, startedAt: startedAt, project: project, bytesFreed: 0, summary: summary,
                        errors: [Self.describe(failure)]),
                    loadContext())
                throw failure
            }
        }
    }

    /// Puts `project` back on the package manager it used before its latest conversion, under the job
    /// lock, and appends a `.revert` record. The backup is removed once the revert succeeds.
    public func revert(
        _ project: Project, using commands: CommandRunner? = nil, onWaiting: (() -> Void)? = nil
    ) throws {
        try withLock(onWaiting: onWaiting) {
            guard let backup = ConversionBackup.latest(for: project.root, paths: paths) else {
                throw ConversionFailure(
                    step: .backingUp, command: "", output: "There is no conversion backup to revert to.",
                    reverted: false)
            }
            let name = project.root.lastPathComponent
            let manager = backup.originalManager.rawValue
            let startedAt = Date()
            let converter = PnpmConverter(runner: commands ?? runner, paths: paths, rewriter: ConfigRewriter())
            do {
                try converter.revert(project, backup: backup)
                try? backup.delete(paths: paths)
                _ = finish(
                    conversionRecord(
                        .revert, startedAt: startedAt, project: project, bytesFreed: 0,
                        summary: "Reverted \(name) to \(manager)", errors: []),
                    loadContext())
            } catch let failure as ConversionFailure {
                _ = finish(
                    conversionRecord(
                        .revert, startedAt: startedAt, project: project, bytesFreed: 0,
                        summary: "Reverting \(name) to \(manager) failed", errors: [Self.describe(failure)]),
                    loadContext())
                throw failure
            }
        }
    }

    private func conversionRecord(
        _ kind: JobKind, startedAt: Date, project: Project, bytesFreed: Int64, summary: String, errors: [String]
    ) -> RunRecord {
        RunRecord(
            id: UUID(), kind: kind, trigger: .manualApp, startedAt: startedAt, finishedAt: Date(),
            bytesFreed: bytesFreed, summary: summary, projects: [project.root.path], skipped: [], errors: errors,
            lastFSEventID: FSEventsGetCurrentEventId())
    }

    /// The failed command and the end of its output, short enough for one history line.
    private static func describe(_ failure: ConversionFailure) -> String {
        let output = failure.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = output.count > 2_000 ? "…" + output.suffix(2_000) : output
        let command = failure.command.isEmpty ? "" : "\(failure.command): "
        return "Failed while \(failure.step.displayText): \(command)\(tail)"
    }

    // MARK: Refreshing derived state

    /// Re-measures shared bytes and writes `stats.json` (a failed write is not reported here).
    @discardableResult
    public func refreshSavings() -> SavingsSnapshot {
        let context = loadContext()
        return writeSavings(context.allProjects)
    }

    /// Rebuilds and writes `projects.json` (a failed write is not reported here).
    @discardableResult
    public func refreshSummaries() -> [ProjectSummary] {
        let context = loadContext()
        return writeSummaries(
            context, savings: readSavings() ?? SavingsSnapshot(measuredAt: Date()), clearedBytes: [:]
        ).summaries
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
        let all = ProjectScanner(excludedDirectoryNames: ProjectScanner.excludedNames(for: settings), home: paths.home)
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

    /// Appends the record, then refreshes savings and summaries. Returns a message for each
    /// file that could not be written.
    private func finish(
        _ record: RunRecord, _ context: Context, clearedBytes: [String: Int64] = [:]
    ) -> [String] {
        var failures: [String] = []
        do {
            try history.append(record)
        } catch {
            failures.append("history: \(error.localizedDescription)")
        }
        let savings = SavingsMeter().measure(projects: context.allProjects, now: Date())
        failures += write(savings, to: paths.stats)
        failures += writeSummaries(context, savings: savings, clearedBytes: clearedBytes).errors
        return failures
    }

    private func writeSavings(_ projects: [Project]) -> SavingsSnapshot {
        let snapshot = SavingsMeter().measure(projects: projects, now: Date())
        _ = write(snapshot, to: paths.stats)
        return snapshot
    }

    private func readSavings() -> SavingsSnapshot? {
        guard let data = try? Data(contentsOf: paths.stats) else { return nil }
        return try? JSONDecoder().decode(SavingsSnapshot.self, from: data)
    }

    private func writeSummaries(
        _ context: Context, savings: SavingsSnapshot, clearedBytes: [String: Int64]
    ) -> (summaries: [ProjectSummary], errors: [String]) {
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
                // Never store credentials that may be embedded in the URL.
                remoteURL: repo.flatMap { git.remoteURL($0, remote: "origin") }.map(RemoteURL.withoutCredentials),
                skipReason: ProjectSummary.blockingSkip(candidates))
        }
        return (summaries, write(summaries, to: paths.projects))
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

    /// Writes `value` as JSON; returns a message if that failed.
    private func write<T: Encodable>(_ value: T, to url: URL) -> [String] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(value)
            try paths.ensureExists()
            try data.write(to: url, options: .atomic)
            return []
        } catch {
            return ["\(url.lastPathComponent): \(error.localizedDescription)"]
        }
    }

    // MARK: Text

    private static func projects(_ count: Int) -> String {
        count == 1 ? "1 project" : "\(count) projects"
    }

    private static func lockFailure(_ error: Error) -> String {
        "Could not take the job lock, nothing was run: \(error.localizedDescription)"
    }

    /// "linkbreeze/.next: Active in the last 24 hours"
    private static func skippedText(_ candidate: CacheCandidate, activityWindowHours: Int) -> String {
        let project = URL(fileURLWithPath: candidate.projectRoot).lastPathComponent
        let reason = candidate.skip?.displayText(activityWindowHours: activityWindowHours) ?? "Skipped"
        return "\(project)/\(candidate.relativePath): \(reason)"
    }
}
