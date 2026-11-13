import CoreServices
import Darwin
import FeatherweightCore
import Foundation

/// The background helper: watches project folders for installs, runs scheduled and after-install
/// jobs, and posts notifications. Everything here runs on the main thread; jobs and project scans
/// run on background-QoS queues. Between events the process sleeps: one `FSEventStream`, one
/// state-directory source and one timer set to the next thing that is due.
@MainActor
final class HelperService {
    /// Rescan for new projects at most this often when installs land outside known projects.
    private static let rescanInterval: TimeInterval = 60
    /// How long after a job to wait for its `history.jsonl` event before treating events as new.
    private static let fenceTimeout: TimeInterval = 30
    /// How long to keep another process's record waiting for its `history.jsonl` event.
    private static let unfencedLifetime: TimeInterval = 300

    private let paths: AppPaths
    private let history: HistoryStore
    private let jobs: JobRunner
    private let notifier = Notifier()
    private lazy var watcher = FSEventsWatcher { [unowned self] in self.handle($0) }
    /// Drains autoreleased objects after each job instead of keeping them for the thread's lifetime.
    private let jobQueue = DispatchQueue(
        label: "com.novacoax.featherweight.helper.jobs", qos: .background, autoreleaseFrequency: .workItem)
    private let scanQueue = DispatchQueue(label: "com.novacoax.featherweight.helper.scan", qos: .background)

    private var settings: Settings
    /// Known projects, with `nodeModules` set (whether or not it exists yet) to its physical path,
    /// so events for a first install and for symlinked folders still match.
    private var projects: [Project] = []
    /// Physical paths of the known project roots.
    private var projectRoots: Set<String> = []
    private var lastRescan: Date?

    private var debouncer = InstallDebouncer()
    private var composer = NotificationComposer()
    /// Events at or below this ID came from a finished job: the highest `lastFSEventID` in history,
    /// or the ID of the latest `history.jsonl` event (written when a job ends), whichever is higher.
    private var ignoreAtOrBelow: UInt64 = 0
    private var seenRecords: Set<UUID> = []
    /// Records read from history whose `history.jsonl` event the stream has not delivered yet.
    /// Another process's job (the CLI, the app) renames files after its `lastFSEventID` too, and
    /// those events can reach the debouncer before its history event; when that event arrives,
    /// pending projects the job worked on with no later event are dropped (Review Focus 2).
    private var unfencedRecords: [RunRecord] = []
    /// Physical path of `history.jsonl`, as FSEvents reports it.
    private var historyEventPath = ""

    /// Jobs queued or running, and the event ID current when the helper became busy. Events after
    /// that ID may be the jobs' own changes, so they are skipped until the jobs are done.
    ///
    /// FSEvents lag (Review Focus 2): a record's `lastFSEventID` can be lower than the IDs of the
    /// job's own last changes, because fseventsd numbers events a moment after they happen
    /// (observed: record 574888238, the job's own renames 574888243-574888283, delivered after the
    /// job had finished). So after the last job the helper stays busy until the stream delivers
    /// that job's `history.jsonl` append (written after all of the job's changes, so numbered
    /// after them), or `fenceTimeout` passes. See `handle(_:)` and `finished(...)`.
    private var jobsInFlight = 0
    private var busySinceEventID: UInt64 = 0
    private var pendingFence: (above: UInt64, deadline: Date)?
    private var queuedScheduled: Set<JobKind> = []

    private var isBusy: Bool { jobsInFlight > 0 || pendingFence != nil }

    private var timer: DispatchSourceTimer?
    private var stateSource: DispatchSourceFileSystemObject?
    private lazy var wakeWatcher = WakeWatcher { [unowned self] in self.didWake() }

    init(paths: AppPaths) {
        self.paths = paths
        history = HistoryStore(url: paths.history)
        jobs = JobRunner(paths: paths)
        settings = SettingsStore(paths: paths).load()
    }

    func start() {
        do {
            try HelperHeartbeat(paths: paths).write(pid: getpid())
        } catch {
            HelperLog.line("could not write heartbeat: \(error.localizedDescription)")
        }
        notifier.requestAuthorization()
        settings = SettingsStore(paths: paths).load()
        debouncer.excludedRelativePaths = InstallDebouncer.excludedRelativePaths(cacheFolders: settings.cacheFolders)
        readHistory(notify: false)
        rescanProjects()
        watchStateDirectory()
        historyEventPath = (PhysicalPath.resolve(paths.base.path) ?? paths.base.path) + "/"
            + paths.history.lastPathComponent
        watcher.watch(watchedFolders)
        startTimer()
        wakeWatcher.start()
        runOverdueJobs()
        reschedule()
    }

    // MARK: Events

    /// The project folders plus the state directory (for `history.jsonl` events); nothing when no
    /// project folders are configured.
    private var watchedFolders: [String] {
        settings.projectFolders.isEmpty ? [] : settings.projectFolders + [paths.base.path]
    }

    /// Events arrive in ID order.
    private func handle(_ events: [FileEvent]) {
        let now = Date()
        if let fence = pendingFence, now >= fence.deadline { pendingFence = nil }
        var unknownProject = false
        var historyEventID: UInt64?
        for event in events {
            if event.path == historyEventPath {
                // A job just ended: every event before this one is at or below its end.
                historyEventID = event.id
                ignoreAtOrBelow = max(ignoreAtOrBelow, event.id)
                if jobsInFlight == 0, let fence = pendingFence, event.id > fence.above { pendingFence = nil }
                continue
            }
            if isBusy, event.id > busySinceEventID { continue }
            if event.isGlobalDrop || event.mustScanSubDirs {
                // Events were lost, so any project there may have been installed into.
                debouncer.recordDroppedEvents(
                    under: event.isGlobalDrop ? nil : event.path, eventID: event.id, at: now,
                    ignoreAtOrBelow: ignoreAtOrBelow, projects: projects)
                continue
            }
            debouncer.record(
                path: event.path, eventID: event.id, at: now, ignoreAtOrBelow: ignoreAtOrBelow,
                projects: projects)
            if !unknownProject, event.id > ignoreAtOrBelow, let root = Self.rootBeforeNodeModules(event.path),
               !projectRoots.contains(root) {
                unknownProject = true
            }
        }
        if let historyEventID { fence(atHistoryEvent: historyEventID, now: now) }
        if unknownProject, lastRescan.map({ now.timeIntervalSince($0) >= Self.rescanInterval }) ?? true {
            rescanProjects()
        }
        reschedule()
    }

    /// The stream delivered a `history.jsonl` append with ID `eventID`: every record finished before
    /// it is now fenced, so drop pending projects those jobs worked on with no later event (their
    /// own renames, numbered after the record's `lastFSEventID` but before this event).
    private func fence(atHistoryEvent eventID: UInt64, now: Date) {
        readHistory(notify: true)
        unfencedRecords.removeAll { record in
            if record.lastFSEventID < eventID {
                debouncer.forget(atOrBelow: eventID, inProjects: record.projects)
                return true
            }
            return now.timeIntervalSince(record.finishedAt) > Self.unfencedLifetime
        }
    }

    /// "/dev/app" for "/dev/app/node_modules/x"; nil when the path is not in a `node_modules`.
    private static func rootBeforeNodeModules(_ path: String) -> String? {
        path.range(of: "/node_modules/").map { String(path[..<$0.lowerBound]) }
    }

    private func didWake() {
        runOverdueJobs()
        reschedule()
    }

    // MARK: State directory

    private func watchStateDirectory() {
        do {
            try paths.ensureExists()
        } catch {
            HelperLog.line("could not create \(paths.base.path): \(error.localizedDescription)")
        }
        let fd = open(paths.base.path, O_EVTONLY)
        guard fd >= 0 else {
            HelperLog.line("could not watch \(paths.base.path)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [unowned self] in
            MainActor.assumeIsolated { self.stateDirectoryChanged() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        stateSource = source
    }

    /// Settings were saved or a job finished (every job rewrites `stats.json` and `projects.json`).
    private func stateDirectoryChanged() {
        let old = settings
        settings = SettingsStore(paths: paths).load()
        debouncer.excludedRelativePaths = InstallDebouncer.excludedRelativePaths(cacheFolders: settings.cacheFolders)
        if settings.projectFolders != old.projectFolders {
            watcher.watch(watchedFolders)
        }
        if settings.projectFolders != old.projectFolders || settings.cacheFolders != old.cacheFolders {
            rescanProjects()
        }
        readHistory(notify: true)
        if !old.automaticWorkAllowed, settings.automaticWorkAllowed {
            runOverdueJobs()
        }
        reschedule()
    }

    /// Raises `ignoreAtOrBelow` to the newest job's event ID (never above the current event ID)
    /// and, with `notify` (after startup), tracks new records until their history event arrives and
    /// queues runs other processes recorded (the CLI) for notification. The helper's own runs are
    /// queued when they finish, with their project names.
    private func readHistory(notify: Bool) {
        let records = history.all()
        ignoreAtOrBelow = max(
            ignoreAtOrBelow,
            InstallDebouncer.ignoreThreshold(
                lastEventIDs: records.map(\.lastFSEventID), currentEventID: FSEventsGetCurrentEventId()))
        for record in records.reversed() where seenRecords.insert(record.id).inserted {
            guard notify else { continue }
            unfencedRecords.append(record)
            if record.trigger != .scheduled, record.trigger != .afterInstall {
                composer.add(record, projectName: nil)
            }
        }
    }

    // MARK: Projects

    private func rescanProjects() {
        lastRescan = Date()
        let settings = settings
        let home = paths.home
        scanQueue.async { [weak self] in
            let found = ProjectScanner(excludedDirectoryNames: ProjectScanner.excludedNames(for: settings), home: home)
                .scan(folders: settings.projectFolders.map { URL(fileURLWithPath: $0, isDirectory: true) })
            let roots = found.map { PhysicalPath.resolve($0.root.path) ?? $0.root.path }
            let matchable = zip(found, roots).map { project, root in
                var project = project
                project.nodeModules = URL(fileURLWithPath: root + "/node_modules", isDirectory: true)
                return project
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.projects = matchable
                    self?.projectRoots = Set(roots)
                }
            }
        }
    }

    // MARK: Jobs

    private func runOverdueJobs(now: Date = Date()) {
        guard settings.automaticWorkAllowed else { return }
        let records = history.all()
        let scheduled: [(JobKind, Schedule)] = [(.dedupe, settings.dedupeSchedule), (.clean, settings.cleanSchedule)]
        for (kind, schedule) in scheduled where !queuedScheduled.contains(kind) {
            // After-install runs cover a single project, so they do not count as the sweep.
            // No sweep recorded yet means first launch's own runs (started by "Start saving
            // space") are still going: wait for the schedule instead of sweeping twice.
            guard let lastRun = records.first(where: { $0.kind == kind && $0.trigger != .afterInstall })?.finishedAt
            else { continue }
            if schedule.isOverdue(lastRun: lastRun, now: now, calendar: .current) {
                queuedScheduled.insert(kind)
                enqueue(kind, trigger: .scheduled, only: nil, projectName: nil, frequency: schedule.frequency)
            }
        }
    }

    private func enqueue(
        _ kind: JobKind, trigger: JobTrigger, only roots: [URL]?, projectName: String?,
        frequency: Schedule.Frequency?
    ) {
        if !isBusy { busySinceEventID = FSEventsGetCurrentEventId() }
        jobsInFlight += 1
        let jobs = jobs
        let paths = paths
        jobQueue.async { [weak self] in
            let errors: [String]
            let record: RunRecord?
            if !SettingsStore(paths: paths).load().automaticWorkAllowed {
                // Paused (or first launch not finished) after this job was queued: skip it, but
                // still report back so the in-flight bookkeeping unwinds.
                (errors, record) = (["paused"], nil)
            } else if kind == .clean {
                let result = jobs.clean(trigger: trigger, only: roots, dryRun: false)
                (errors, record) = (result.0.errors, result.1)
            } else {
                let result = jobs.dedupe(trigger: trigger, only: roots, dryRun: false)
                (errors, record) = (result.0.errors, result.1)
            }
            // Hand the job's freed memory back to the system, so the idle helper stays small
            // instead of keeping its peak until macOS asks for it.
            malloc_zone_pressure_relief(nil, 0)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.finished(kind, trigger: trigger, record: record, errors: errors,
                                   projectName: projectName, frequency: frequency)
                }
            }
        }
    }

    private func finished(
        _ kind: JobKind, trigger: JobTrigger, record: RunRecord?, errors: [String], projectName: String?,
        frequency: Schedule.Frequency?
    ) {
        jobsInFlight -= 1
        if trigger == .scheduled { queuedScheduled.remove(kind) }
        if let record {
            seenRecords.insert(record.id)
            ignoreAtOrBelow = max(ignoreAtOrBelow, record.lastFSEventID)
            pendingFence = (record.lastFSEventID, Date().addingTimeInterval(Self.fenceTimeout))
            composer.add(record, projectName: projectName, frequency: frequency)
        } else {
            errors.forEach { HelperLog.line("\(kind.rawValue) did not run: \($0)") }
        }
        reschedule()
    }

    // MARK: Timer

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.setEventHandler { [unowned self] in
            MainActor.assumeIsolated { self.timerFired() }
        }
        timer.schedule(wallDeadline: .distantFuture)
        timer.resume()
        self.timer = timer
    }

    private func timerFired() {
        let now = Date()
        if settings.automaticWorkAllowed {
            let roots = debouncer.due(now: now)
            if !roots.isEmpty {
                let name = roots.map(\.lastPathComponent).joined(separator: ", ")
                enqueue(.dedupe, trigger: .afterInstall, only: roots, projectName: name, frequency: nil)
            }
            runOverdueJobs(now: now)
        }
        if let text = composer.flush(now: now), settings.notificationsEnabled {
            notifier.post(text)
        }
        reschedule()
    }

    /// Sets the timer to the earliest of: the next install that settles, the next scheduled jobs
    /// and the next notification flush. While paused only the flush counts (events still collect).
    private func reschedule() {
        guard let timer else { return }
        let now = Date()
        var candidates: [Date] = []
        if settings.automaticWorkAllowed {
            candidates.append(settings.dedupeSchedule.nextRun(after: now, calendar: .current))
            candidates.append(settings.cleanSchedule.nextRun(after: now, calendar: .current))
            if let due = debouncer.nextDue { candidates.append(due) }
        }
        if let flush = composer.nextFlush { candidates.append(flush) }
        guard let next = candidates.min() else {
            timer.schedule(wallDeadline: .distantFuture)
            return
        }
        // Wall-clock deadline, so the timer keeps counting while the Mac sleeps.
        timer.schedule(wallDeadline: .now() + max(0, next.timeIntervalSince(now)), leeway: .seconds(1))
    }
}
