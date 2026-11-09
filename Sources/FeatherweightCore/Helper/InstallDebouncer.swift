import Foundation

/// Turns file-system events into "this project finished installing" signals: a project is due once
/// its `node_modules` has had no events for `quietPeriod`.
///
/// Projects are matched by their `nodeModules` path, and a project's root for matching is that
/// path's parent (the helper sets it to the physical path FSEvents reports).
public struct InstallDebouncer: Sendable {
    public let quietPeriod: TimeInterval
    /// Folders under a project root whose events never count, such as `node_modules/.cache`,
    /// which dev servers write to constantly.
    public var excludedRelativePaths: [String]

    private struct Entry: Sendable {
        let root: URL
        var at: Date
        var lastEventID: UInt64
    }

    /// Pending projects by root path.
    private var entries: [String: Entry] = [:]

    public init(quietPeriod: TimeInterval = 60, excludedRelativePaths: [String] = []) {
        self.quietPeriod = quietPeriod
        self.excludedRelativePaths = excludedRelativePaths
    }

    /// `node_modules/.cache`, `node_modules/.vite` and every cache folder setting inside
    /// `node_modules` (on or off), sorted.
    public static func excludedRelativePaths(cacheFolders: [CacheFolderSetting]) -> [String] {
        let configured = cacheFolders.map(\.relativePath).filter { $0.hasPrefix("node_modules/") }
        return Set(["node_modules/.cache", "node_modules/.vite"] + configured).sorted()
    }

    /// The highest of `lastEventIDs` (each job's last event ID), but never above the current
    /// event ID: history copied from another Mac, or written before the event database was reset,
    /// must not silence every new event.
    public static func ignoreThreshold(lastEventIDs: [UInt64], currentEventID: UInt64) -> UInt64 {
        min(lastEventIDs.max() ?? 0, currentEventID)
    }

    /// Counts an event when its path is inside a project's `node_modules` (outside the excluded
    /// folders) and its ID is above `ignoreAtOrBelow` (events at or below it came from
    /// Featherweight's own jobs). The event is credited to the project with the longest matching
    /// `node_modules` path, so nested projects win.
    public mutating func record(
        path: String, eventID: UInt64, at date: Date, ignoreAtOrBelow: UInt64, projects: [Project]
    ) {
        guard eventID > ignoreAtOrBelow, path.contains("/node_modules/") else { return }
        guard let project = innermostProject(containing: path, projects), !isExcluded(path, in: project) else { return }
        touch(project.root, eventID: eventID, at: date)
    }

    /// The system dropped events (MustScanSubDirs, or a user/kernel drop when `path` is nil), so
    /// any project there may have been installed into. Counts activity for every project whose
    /// root is at or under `path` and for the project whose `node_modules` contains `path`; with
    /// no path, for every project.
    public mutating func recordDroppedEvents(
        under path: String?, eventID: UInt64, at date: Date, ignoreAtOrBelow: UInt64, projects: [Project]
    ) {
        guard eventID > ignoreAtOrBelow else { return }
        guard let path else {
            projects.forEach { touch($0.root, eventID: eventID, at: date) }
            return
        }
        for project in projects {
            let root = Self.matchRoot(project)
            if root == path || root.hasPrefix(path + "/") { touch(project.root, eventID: eventID, at: date) }
        }
        if let project = innermostProject(containing: path + "/", projects), !isExcluded(path, in: project) {
            touch(project.root, eventID: eventID, at: date)
        }
    }

    /// Another process's job ended with its `history.jsonl` event at `eventID`. Its own changes in
    /// the projects it worked on are numbered at or below that, so pending projects among
    /// `projectPaths` whose last event is no later are dropped. Paths are compared physically.
    public mutating func forget(atOrBelow eventID: UInt64, inProjects projectPaths: [String]) {
        let covered = Set(projectPaths.map { PhysicalPath.resolve($0) ?? $0 })
        entries = entries.filter { _, entry in
            entry.lastEventID > eventID || !covered.contains(PhysicalPath.resolve(entry.root.path) ?? entry.root.path)
        }
    }

    /// When the earliest pending project becomes due, if any.
    public var nextDue: Date? {
        entries.values.map(\.at).min().map { $0.addingTimeInterval(quietPeriod) }
    }

    /// Project roots whose last event is at least `quietPeriod` old, sorted by path. They are removed.
    public mutating func due(now: Date) -> [URL] {
        let ready = entries.filter { now.timeIntervalSince($0.value.at) >= quietPeriod }
        for key in ready.keys { entries[key] = nil }
        return ready.sorted { $0.key < $1.key }.map(\.value.root)
    }

    // MARK: Internals

    private mutating func touch(_ root: URL, eventID: UInt64, at date: Date) {
        let previous = entries[root.path]
        entries[root.path] = Entry(
            root: root, at: max(previous?.at ?? date, date), lastEventID: max(previous?.lastEventID ?? 0, eventID))
    }

    /// The project with the longest `node_modules` path that `path` is inside.
    private func innermostProject(containing path: String, _ projects: [Project]) -> Project? {
        var best: (project: Project, length: Int)?
        for project in projects {
            guard let nodeModules = project.nodeModules?.path, path.hasPrefix(nodeModules + "/") else { continue }
            if nodeModules.count > best?.length ?? -1 { best = (project, nodeModules.count) }
        }
        return best?.project
    }

    private func isExcluded(_ path: String, in project: Project) -> Bool {
        guard let nodeModules = project.nodeModules?.path else { return false }
        let relative = "node_modules" + path.dropFirst(nodeModules.count)
        return excludedRelativePaths.contains { relative == $0 || relative.hasPrefix($0 + "/") }
    }

    private static func matchRoot(_ project: Project) -> String {
        project.nodeModules?.deletingLastPathComponent().path ?? project.root.path
    }
}
