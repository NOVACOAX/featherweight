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
    /// The open "Convert to pnpm…" flow, if any.
    var conversion: ConversionSession?
    /// Project path → the package manager its latest conversion backup can put back.
    var revertTargets: [String: PackageManager] = [:]
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
        var targets: [String: PackageManager] = [:]
        for project in projects where project.packageManager == .pnpm {
            let root = URL(fileURLWithPath: project.id, isDirectory: true)
            if let backup = ConversionBackup.latest(for: root, paths: paths) { targets[project.id] = backup.originalManager }
        }
        revertTargets = targets
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

    // MARK: Converting to pnpm

    /// Why `project` can't be converted right now, or nil when it can. Only asked for npm and yarn
    /// projects; uses the activity the last scan recorded rather than scanning again.
    func conversionBlocker(for project: ProjectSummary) -> String? {
        let session = Project(
            root: URL(fileURLWithPath: project.id, isDirectory: true), parentRoot: nil,
            packageManager: project.packageManager, nodeModules: nil)
        return ConversionEligibility.check(session, recentlyActive: project.skipReason == .recentlyActive)?
            .message(windowHours: settings.activityWindowHours)
    }

    /// Opens the conversion sheets for `project`, starting with a check that pnpm 10+ is installed.
    func startConversion(of project: ProjectSummary) {
        guard conversion == nil else { return }
        let session = ConversionSession(summary: project)
        conversion = session
        Task { await checkPnpm(session) }
    }

    private func checkPnpm(_ session: ConversionSession) async {
        session.phase = .checkingPnpm
        let (version, supported) = await Task.detached {
            let toolchain = PnpmToolchain(runner: ProcessCommandRunner())
            let version = toolchain.installedVersion()
            return (version, version.map(toolchain.isSupported) ?? false)
        }.value
        session.phase = supported ? .confirm : .needsPnpm(found: version)
    }

    /// Runs the first pnpm install command that works (Corepack, then npm), then checks again.
    func installPnpm(_ session: ConversionSession) async {
        session.phase = .installingPnpm
        session.installError = nil
        let failure: String? = await Task.detached {
            do {
                _ = try PnpmToolchain(runner: ProcessCommandRunner()).install()
                return nil
            } catch let error as PnpmInstallError {
                return error.output
            } catch {
                return "\(error)"
            }
        }.value
        session.installError = failure
        await checkPnpm(session)
        if case .needsPnpm(let found?) = session.phase, failure == nil {
            session.installError = "pnpm \(found) is still the one found first on your PATH."
        }
    }

    /// Converts the session's project inside the job lock, showing each step and command.
    func convert(_ session: ConversionSession) async {
        if let refusal = begin(.convert) {
            session.phase = .failed(ConversionFailure(step: .backingUp, command: "", output: refusal, reverted: true))
            return
        }
        session.log = []
        session.waitingForLock = false
        session.phase = .running(.backingUp)
        let project = session.project
        let buildCheck = session.runBuildCheck && session.hasBuildScript
        let paths = paths
        enum Outcome: Sendable {
            case done(ConversionResult, ConversionSession.GitTarget?)
            case failed(ConversionFailure)
        }
        let outcome: Outcome = await Task.detached(priority: .userInitiated) { [weak session] in
            let commands = LoggingCommandRunner(base: ProcessCommandRunner()) { line in
                Task { @MainActor in session?.log.append(line) }
            }
            do {
                let result = try JobRunner(paths: paths).convert(
                    project, runBuildCheck: buildCheck, using: commands,
                    onWaiting: { Task { @MainActor in session?.waitingForLock = true } }
                ) { step in
                    Task { @MainActor in session?.report(step) }
                }
                return .done(result, Self.gitTarget(for: project.root))
            } catch let failure as ConversionFailure {
                return .failed(failure)
            } catch {
                // Only the job lock throws anything else, and then nothing ran.
                return .failed(ConversionFailure(
                    step: .backingUp, command: "", output: Self.lockFailureText(error), reverted: true))
            }
        }.value
        runningJob = nil
        waitingForLock = false
        session.waitingForLock = false
        switch outcome {
        case .done(let result, let git):
            session.git = git
            session.phase = .done(result)
        case .failed(let failure):
            session.phase = .failed(failure)
        }
        reload()
    }

    /// Reverts from the done sheet; the sheet closes when the project is back on npm or yarn.
    func revertConversion(_ session: ConversionSession) async {
        session.phase = .reverting
        if let failure = await revert(session.project) {
            session.phase = .revertFailed(failure)
        } else {
            conversion = nil
        }
    }

    /// The inspector's "Revert to npm/yarn": shows what went wrong as a notice.
    func revertProject(_ project: ProjectSummary) async {
        let root = URL(fileURLWithPath: project.id, isDirectory: true)
        if let failure = await revert(Project(root: root, parentRoot: nil, packageManager: project.packageManager, nodeModules: nil)) {
            notice = "Reverting \(project.name) failed: \(failure.output)"
        }
    }

    /// Puts `project` back as it was before its latest conversion. Returns the failure, or nil.
    private func revert(_ project: Project) async -> ConversionFailure? {
        if let refusal = begin(.revert) {
            return ConversionFailure(step: .backingUp, command: "", output: refusal, reverted: false)
        }
        let paths = paths
        let failure: ConversionFailure? = await Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try JobRunner(paths: paths).revert(project, onWaiting: { Task { @MainActor in self?.waitingForLock = true } })
                return nil
            } catch let failure as ConversionFailure {
                return failure
            } catch {
                return ConversionFailure(step: .backingUp, command: "", output: Self.lockFailureText(error), reverted: false)
            }
        }.value
        runningJob = nil
        waitingForLock = false
        reload()
        return failure
    }

    /// Commits exactly the files the conversion changed (those git sees as changed), then pushes
    /// when `push` is set. A failed push leaves the commit in place and shows git's output.
    func commitConversion(_ session: ConversionSession, push: Bool) async {
        guard case .done(let result) = session.phase, let git = session.git else { return }
        let message = session.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            session.commit = .failed("Write a commit message first.")
            return
        }
        session.commit = .working(pushing: push)
        let projectRoot = session.project.root
        let state: ConversionSession.CommitState = await Task.detached(priority: .userInitiated) {
            let client = GitClient(runner: ProcessCommandRunner())
            do {
                let wanted = ConversionCommit.repoPaths(result.changes, projectRoot: projectRoot, repoRoot: git.repoRoot)
                let files = try client.changedPaths(wanted, repoRoot: git.repoRoot)
                guard !files.isEmpty else {
                    return .failed("The converted files already match the last commit, so there is nothing to commit.")
                }
                try client.commit(files: files, message: message, repoRoot: git.repoRoot)
                guard push else { return .committed(pushedTo: nil) }
                let pushed = try client.push(repoRoot: git.repoRoot)
                let output = (pushed.stderr + pushed.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
                return pushed.succeeded ? .committed(pushedTo: git.upstream) : .pushFailed(output)
            } catch GitError.commandFailed(let command, _, let stderr) {
                let output = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return .failed(output.isEmpty ? "\(command) failed." : output)
            } catch {
                return .failed("\(error)")
            }
        }.value
        session.commit = state
        reload()
    }

    /// "Commit & Push".
    func pushConversion(_ session: ConversionSession) async {
        await commitConversion(session, push: true)
    }

    /// Closes the conversion sheets.
    func closeConversion() {
        conversion = nil
        reload()
    }

    /// The repository around `root`, its upstream and that remote's address (without credentials).
    private nonisolated static func gitTarget(for root: URL) -> ConversionSession.GitTarget? {
        let git = GitClient(runner: ProcessCommandRunner())
        guard let repoRoot = git.repoRoot(for: root) else { return nil }
        let upstream = git.upstream(repoRoot)
        let remote = upstream
            .flatMap { $0.split(separator: "/").first.map(String.init) }
            .flatMap { git.remoteURL(repoRoot, remote: $0) }
            .flatMap(RemoteURL.hostAndPath)
        return ConversionSession.GitTarget(repoRoot: repoRoot, upstream: upstream, remote: remote)
    }

    private nonisolated static func lockFailureText(_ error: any Error) -> String {
        "Could not take the Featherweight job lock: \(error.localizedDescription)"
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
        if let failure = await installHelper() { notice = failure }
    }

    /// Installs the LaunchAgent; returns the message to show if it was not installed, or nil.
    /// An app still running from a translocated copy is asked to move first: the agent would
    /// point at a path that disappears.
    private func installHelper() async -> String? {
        let helper = HelperLocator.helperExecutable()
        if HelperInstallPolicy.atFirstInstall(helperPath: helper.path) == .askToMove {
            return HelperInstallPolicy.moveNotice
        }
        return await runInstall(helper: helper)
    }

    private func runInstall(helper: URL) async -> String? {
        let paths = paths
        let failure: String? = await Task.detached {
            do {
                try LaunchAgent(paths: paths, runner: ProcessCommandRunner()).install(helperExecutable: helper)
                return nil
            } catch {
                return "Could not start the helper: \(error.localizedDescription)"
            }
        }.value
        reload()
        return failure
    }

    @ObservationIgnored private var checkedHelperLocation = false

    /// On launch, installs the LaunchAgent again if it points at a different helper than this
    /// app's (the app was moved). Checked once per run.
    func reinstallHelperIfMoved() async {
        guard !checkedHelperLocation else { return }
        checkedHelperLocation = true
        let helper = HelperLocator.helperExecutable()
        let paths = paths
        let installedPath = await Task.detached { LaunchAgent(paths: paths, runner: ProcessCommandRunner()).installedHelperPath() }.value
        switch HelperInstallPolicy.atLaunch(
            onboardingComplete: settings.onboardingComplete, installedPath: installedPath, helperPath: helper.path)
        {
        case .skip: break
        case .askToMove: notice = HelperInstallPolicy.moveNotice
        case .install: if let failure = await runInstall(helper: helper) { notice = failure }
        }
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
                // The user is waiting on this screen, so it runs ahead of background work.
                let found = await Task.detached(priority: .utility) {
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
        if let failure = await installHelper() { problems.append(failure) }
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
