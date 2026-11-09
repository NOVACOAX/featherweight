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
        cliCommandInstalled = !Self.cliInstaller(paths: paths, pathEnv: "").installedLinks().isEmpty
    }

    private static func cliInstaller(paths: AppPaths, pathEnv: String) -> CLIInstaller {
        CLIInstaller(home: paths.home, pathEnv: pathEnv)
    }

    // MARK: Jobs

    func runDedupe(preview: Bool, trigger: JobTrigger = .manualApp) async {
        guard begin(.dedupe) else { return }
        let paths = paths
        let (report, record) = await Task.detached(priority: .background) { [weak self] in
            // Made here, not on the main actor: it reads the login-shell environment, which can take seconds.
            JobRunner(paths: paths).dedupe(trigger: trigger, dryRun: preview) {
                Task { @MainActor in self?.waitingForLock = true }
            }
        }.value
        finish(preview: preview, record: record, errors: report.errors) { .dedupe(report) }
    }

    func runClean(preview: Bool, only: [URL]? = nil, trigger: JobTrigger = .manualApp) async {
        guard begin(.clean) else { return }
        let paths = paths
        let (report, record) = await Task.detached(priority: .background) { [weak self] in
            JobRunner(paths: paths).clean(trigger: trigger, only: only, dryRun: preview) {
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
                    try CLIInstaller(home: paths.home, pathEnv: "").uninstall()
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

    /// "Start saving space": saves the settings as complete, starts the helper, then shares
    /// duplicates and clears caches once. The first launch window gives way to the main window as
    /// soon as the settings are saved, so progress shows on the Overview.
    func startSavingSpace() async {
        var updated = SettingsStore(paths: paths).load()
        updated.onboardingComplete = true
        guard saveSettings(updated) else { return }

        // Each job clears the notice when it starts, so collect what goes wrong and show it at the end.
        var problems: [String] = []
        if let failure = await installHelper() { problems.append("Could not start the helper: \(failure)") }
        await runDedupe(preview: false, trigger: .firstLaunch)
        if let notice { problems.append(notice) }
        await runClean(preview: false, trigger: .firstLaunch)
        if let notice { problems.append(notice) }
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
