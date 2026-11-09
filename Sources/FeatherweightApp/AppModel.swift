import FeatherweightCore
import Foundation
import Observation

/// What a dry run found. Shown in the Preview sheet.
enum PreviewResult: Identifiable, Equatable {
    case dedupe(DedupeReport)
    case clean(CleanReport)

    var id: String {
        switch self {
        case .dedupe: "dedupe"
        case .clean: "clean"
        }
    }
}

/// Everything the windows show, read from the state directory, plus the actions they trigger.
///
/// The helper and the CLI write to the same state directory, so the model watches it and reloads
/// when anything in it changes.
@MainActor @Observable
final class AppModel {
    var settings: Settings
    var savings: SavingsSnapshot?
    /// Newest first.
    var history: [RunRecord] = []
    var projects: [ProjectSummary] = []
    var helperRunning = false
    var disk: (free: Int64, total: Int64)?
    var volumeName: String?
    var cachesClearedThisMonth: Int64 = 0
    var runningJob: JobKind?
    var waitingForLock = false
    var previewResult: PreviewResult?
    /// A problem the user should see (a job that did not run, a file that could not be saved).
    var notice: String?

    @ObservationIgnored let paths: AppPaths
    @ObservationIgnored private let jobs: JobRunner
    @ObservationIgnored private var watcher: StateDirectoryWatcher?

    init(paths: AppPaths = .resolved(environment: ProcessInfo.processInfo.environment)) {
        self.paths = paths
        jobs = JobRunner(paths: paths)
        settings = SettingsStore(paths: paths).load()
        reload()
    }

    /// Starts reloading whenever a file in the state directory is created, replaced or removed.
    func startWatching() {
        guard watcher == nil else { return }
        try? paths.ensureExists()
        watcher = StateDirectoryWatcher(directory: paths.base) { [weak self] in self?.reload() }
    }

    func reload() {
        settings = SettingsStore(paths: paths).load()
        savings = Self.decode(SavingsSnapshot.self, from: paths.stats)
        projects = Self.decode([ProjectSummary].self, from: paths.projects) ?? []
        let store = HistoryStore(url: paths.history)
        history = store.all()
        cachesClearedThisMonth = store.cachesClearedThisMonth(now: Date(), calendar: .current)
        helperRunning = HelperHeartbeat(paths: paths).isAlive()
        disk = try? DiskSpace.forVolume(containing: paths.home)
        volumeName = try? paths.home.resourceValues(forKeys: [.volumeNameKey]).volumeName
    }

    // MARK: Jobs

    func runDedupe(preview: Bool) async {
        guard begin(.dedupe) else { return }
        let jobs = jobs
        let (report, record) = await Task.detached(priority: .background) { [weak self] in
            jobs.dedupe(trigger: .manualApp, dryRun: preview) {
                Task { @MainActor in self?.waitingForLock = true }
            }
        }.value
        finish(preview: preview, record: record, errors: report.errors) { .dedupe(report) }
    }

    func runClean(preview: Bool, only: [URL]? = nil) async {
        guard begin(.clean) else { return }
        let jobs = jobs
        let (report, record) = await Task.detached(priority: .background) { [weak self] in
            jobs.clean(trigger: .manualApp, only: only, dryRun: preview) {
                Task { @MainActor in self?.waitingForLock = true }
            }
        }.value
        finish(preview: preview, record: record, errors: report.errors) { .clean(report) }
    }

    private func begin(_ kind: JobKind) -> Bool {
        guard runningJob == nil else { return false }
        runningJob = kind
        waitingForLock = false
        notice = nil
        return true
    }

    private func finish(
        preview: Bool, record: RunRecord?, errors: [String], result: () -> PreviewResult
    ) {
        runningJob = nil
        waitingForLock = false
        if preview {
            previewResult = result()
        } else if record == nil {
            // A real run with no record did not run at all; the errors say why.
            notice = errors.isEmpty ? "The job did not run." : errors.joined(separator: "\n")
        }
        reload()
    }

    // MARK: Settings and helper

    func setPaused(_ paused: Bool) {
        // Start from the file, not from `settings`: the CLI may have changed it since the last reload.
        var updated = SettingsStore(paths: paths).load()
        updated.paused = paused
        saveSettings(updated)
    }

    func saveSettings(_ updated: Settings) {
        do {
            try SettingsStore(paths: paths).save(updated)
            settings = updated
        } catch {
            notice = "Could not save settings: \(error.localizedDescription)"
        }
    }

    /// Installs and loads the LaunchAgent that runs the helper.
    func startHelper() async {
        let paths = paths
        let helper = HelperLocator.helperExecutable()
        let failure: String? = await Task.detached {
            do {
                try LaunchAgent(paths: paths, runner: ProcessCommandRunner()).install(helperExecutable: helper)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        if let failure { notice = "Could not start the helper: \(failure)" }
        reload()
    }

    private static func decode<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
