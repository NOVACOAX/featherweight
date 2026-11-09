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
    /// A newer release found on GitHub, shown as a link in the sidebar.
    var availableUpdate: AvailableUpdate?
    /// Whether the LaunchAgent that starts the helper at login is installed.
    var launchAgentInstalled = false
    /// Whether the `featherweight` terminal command is linked into a folder on the user's PATH.
    var cliCommandInstalled = false
    /// Set while the LaunchAgent or the terminal command is being installed or removed.
    var changingLaunchAgent = false
    var changingCLICommand = false
    /// The line to add to the shell's startup file when no folder on PATH could take the command.
    var cliPathSuggestion: String?

    @ObservationIgnored let paths: AppPaths
    @ObservationIgnored private var watcher: StateDirectoryWatcher?

    init(paths: AppPaths = .resolved(environment: ProcessInfo.processInfo.environment)) {
        self.paths = paths
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
        launchAgentInstalled = FileManager.default.fileExists(
            atPath: paths.launchAgentsDir.appendingPathComponent("\(LaunchAgent.label).plist").path)
        cliCommandInstalled = !CLIInstaller(home: paths.home, pathEnv: "")
            .installedLinks(cli: HelperLocator.cliExecutable()).isEmpty
    }

    // MARK: Jobs

    /// Runs the dedupe job. Returns what went wrong with this run (it did not start, or did not
    /// run), or nil. The same text is shown in `notice`.
    @discardableResult
    func runDedupe(preview: Bool, trigger: JobTrigger = .manualApp) async -> String? {
        if let refusal = begin(.dedupe) { return refusal }
        let paths = paths
        let (report, record) = await Task.detached(priority: .background) { [weak self] in
            // Made here, not on the main actor: it reads the login-shell environment, which can take seconds.
            JobRunner(paths: paths).dedupe(trigger: trigger, dryRun: preview) {
                Task { @MainActor in self?.waitingForLock = true }
            }
        }.value
        return finish(preview: preview, record: record, errors: report.errors) { .dedupe(report) }
    }

    /// Runs the clean job; see `runDedupe`.
    @discardableResult
    func runClean(preview: Bool, only: [URL]? = nil, trigger: JobTrigger = .manualApp) async -> String? {
        if let refusal = begin(.clean) { return refusal }
        let paths = paths
        let (report, record) = await Task.detached(priority: .background) { [weak self] in
            JobRunner(paths: paths).clean(trigger: trigger, only: only, dryRun: preview) {
                Task { @MainActor in self?.waitingForLock = true }
            }
        }.value
        return finish(preview: preview, record: record, errors: report.errors) { .clean(report) }
    }

    static let busyNotice = "Another Featherweight job is running. Try again when it has finished."

    /// Marks `kind` as running and clears the last run's notice. If a job is already running it
    /// starts nothing and returns (and shows) why.
    private func begin(_ kind: JobKind) -> String? {
        guard runningJob == nil else {
            notice = Self.busyNotice
            return Self.busyNotice
        }
        runningJob = kind
        waitingForLock = false
        notice = nil
        return nil
    }

    private func finish(
        preview: Bool, record: RunRecord?, errors: [String], result: () -> PreviewResult
    ) -> String? {
        runningJob = nil
        waitingForLock = false
        var problem: String?
        if preview {
            previewResult = result()
        } else if record == nil {
            // A real run with no record did not run at all; the errors say why.
            problem = errors.isEmpty ? "The job did not run." : errors.joined(separator: "\n")
            notice = problem
        }
        reload()
        return problem
    }

    // MARK: Settings and helper

    func setPaused(_ paused: Bool) {
        updateSettings { $0.paused = paused }
    }

    /// Applies `change` to the settings as they are in the file (the CLI may have changed them
    /// since the last reload) and saves them.
    func updateSettings(_ change: (inout Settings) -> Void) {
        var updated = SettingsStore(paths: paths).load()
        change(&updated)
        saveSettings(updated)
    }

    @discardableResult
    func saveSettings(_ updated: Settings) -> Bool {
        do {
            try SettingsStore(paths: paths).save(updated)
            settings = updated
            return true
        } catch {
            notice = "Could not save settings: \(error.localizedDescription)"
            return false
        }
    }

    /// Installs and loads the LaunchAgent that runs the helper.
    func startHelper() async {
        if let failure = await installHelper() { notice = "Could not start the helper: \(failure)" }
    }

    /// Installs the LaunchAgent; returns what went wrong, if anything.
    private func installHelper() async -> String? {
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
        reload()
        return failure
    }

    /// The "Run in background when I log in" switch: installs or removes the LaunchAgent.
    func setLaunchAtLogin(_ enabled: Bool) async {
        guard !changingLaunchAgent else { return }
        changingLaunchAgent = true
        defer { changingLaunchAgent = false }
        if enabled {
            await startHelper()
            return
        }
        let paths = paths
        let failure: String? = await Task.detached {
            do {
                try LaunchAgent(paths: paths, runner: ProcessCommandRunner()).uninstall()
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        if let failure { notice = "Could not stop the helper: \(failure)" }
        reload()
    }

    /// The "Install the featherweight terminal command" switch.
    func setCLICommand(_ enabled: Bool) async {
        guard !changingCLICommand else { return }
        changingCLICommand = true
        defer { changingCLICommand = false }
        cliPathSuggestion = nil
        let paths = paths
        let cli = HelperLocator.cliExecutable()
        enum Outcome: Sendable { case done, needsPath(String), failed(String) }
        let outcome: Outcome = await Task.detached {
            do {
                if enabled {
                    // The login-shell PATH, not the app's own: a Finder launch has almost none.
                    let pathEnv = LoginShellEnvironment.shared["PATH"] ?? ""
                    _ = try CLIInstaller(home: paths.home, pathEnv: pathEnv).install(cli: cli)
                } else {
                    try CLIInstaller(home: paths.home, pathEnv: "").uninstall(cli: cli)
                }
                return .done
            } catch CLIInstallError.noWritableDirectoryOnPath(let line) {
                return .needsPath(line)
            } catch {
                return .failed(error.localizedDescription)
            }
        }.value
        switch outcome {
        case .done: break
        case .needsPath(let line): cliPathSuggestion = line
        case .failed(let message): notice = "Could not \(enabled ? "install" : "remove") the terminal command: \(message)"
        }
        reload()
    }

    // MARK: First launch

    enum FirstLaunchEstimateState: Equatable {
        case noFolder
        case scanning
        case ready(FirstLaunchEstimate)
    }

    /// What the first launch screen shows. "Start saving space" waits for `.ready`.
    private(set) var firstLaunchEstimate = FirstLaunchEstimateState.scanning
    @ObservationIgnored private var estimating = false
    @ObservationIgnored private var estimateAgain = false

    /// Checks the projects folders, then counts what could be saved. Only one count runs at a
    /// time; a request that arrives meanwhile queues one more run with the settings as they are
    /// by then (earlier answers are discarded). Safe to call whenever the settings change.
    func refreshFirstLaunchEstimate() {
        guard !settings.onboardingComplete else { return }
        firstLaunchEstimate = .scanning
        guard !estimating else {
            estimateAgain = true
            return
        }
        estimating = true
        Task {
            repeat {
                estimateAgain = false
                await refuseUnusableFolders()
                if settings.projectFolders.isEmpty {
                    firstLaunchEstimate = .noFolder
                    continue
                }
                let paths = paths
                let found = await Task.detached(priority: .background) {
                    FirstLaunchEstimate.compute(paths: paths)
                }.value
                if !estimateAgain { firstLaunchEstimate = .ready(found) }
            } while estimateAgain && !settings.onboardingComplete
            estimating = false
        }
    }

    /// The default projects folder (and any other folder that did not come through the folder
    /// panel) gets the same check as a chosen one: a folder that is refused is dropped from the
    /// settings, so it is neither counted nor scanned, and the user is told why.
    private func refuseUnusableFolders() async {
        let folders = settings.projectFolders
        guard !folders.isEmpty else { return }
        let home = paths.home
        let result = await Task.detached(priority: .utility) { FolderPolicy(home: home).vet(folders) }.value
        guard !result.refused.isEmpty else { return }
        updateSettings { $0.projectFolders.removeAll { folder in result.refused.contains { $0.path == folder } } }
        notice = result.refused.map { FolderMessages.refusal(for: $0.verdict, folder: $0.path) }.joined(separator: "\n")
    }

    /// "Start saving space": saves the settings as complete, starts the helper, then shares
    /// duplicates and clears caches once. The first launch window gives way to the main window as
    /// soon as the settings are saved, so progress shows on the Overview.
    func startSavingSpace() async {
        var updated = SettingsStore(paths: paths).load()
        updated.onboardingComplete = true
        guard saveSettings(updated) else { return }

        // Each job clears the notice when it starts, so collect what goes wrong in each run
        // and show it all at the end.
        var problems: [String] = []
        if let failure = await installHelper() { problems.append("Could not start the helper: \(failure)") }
        if let problem = await runDedupe(preview: false, trigger: .firstLaunch) { problems.append(problem) }
        if let problem = await runClean(preview: false, trigger: .firstLaunch) { problems.append(problem) }
        notice = problems.isEmpty ? nil : problems.joined(separator: "\n")
    }

    // MARK: Updates

    /// Looks for a newer release when updates are on and the last check was more than a day ago.
    /// A development build has no version to compare, so it never checks.
    func checkForUpdateIfDue(now: Date = Date()) async {
        let current = AppVersion.current
        guard current != "dev" else { return }
        var state = AppState.load(from: paths)
        if let stored = state.availableUpdate, UpdateChecker.isNewer(stored.version, than: current) {
            availableUpdate = stored
        }
        guard UpdateChecker.isDue(lastCheck: state.lastUpdateCheck, now: now, enabled: settings.checkForUpdates)
        else { return }

        // Record the attempt first, so a failing network is not retried on every launch.
        state.lastUpdateCheck = now
        try? state.save(to: paths)
        do {
            let found = try await UpdateChecker().check(current: current, fetch: UpdateChecker.fetchFromGitHub)
            state.availableUpdate = found
            availableUpdate = found
            try? state.save(to: paths)
        } catch {
            // Offline or rate limited: keep what was known and try again tomorrow.
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
