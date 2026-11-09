import Foundation

/// Turns file-system events into "this project finished installing" signals: a project is due once
/// its `node_modules` has had no events for `quietPeriod`.
public struct InstallDebouncer: Sendable {
    public let quietPeriod: TimeInterval
    /// Time of the latest counted event, by project root path.
    private var lastEvent: [String: (root: URL, at: Date)] = [:]

    public init(quietPeriod: TimeInterval = 60) {
        self.quietPeriod = quietPeriod
    }

    /// Counts an event when its path is inside a project's `node_modules` and its ID is above
    /// `ignoreAtOrBelow` (events at or below it came from Featherweight's own jobs). The event is
    /// credited to the project with the longest matching `node_modules` path, so nested projects win.
    public mutating func record(
        path: String, eventID: UInt64, at date: Date, ignoreAtOrBelow: UInt64, projects: [Project]
    ) {
        guard eventID > ignoreAtOrBelow, path.contains("/node_modules/") else { return }
        var best: (project: Project, length: Int)?
        for project in projects {
            guard let nodeModules = project.nodeModules?.path, path.hasPrefix(nodeModules + "/") else { continue }
            if nodeModules.count > best?.length ?? -1 { best = (project, nodeModules.count) }
        }
        guard let project = best?.project else { return }
        lastEvent[project.root.path] = (project.root, date)
    }

    /// When the earliest pending project becomes due, if any.
    public var nextDue: Date? {
        lastEvent.values.map(\.at).min().map { $0.addingTimeInterval(quietPeriod) }
    }

    /// Project roots whose last event is at least `quietPeriod` old, sorted by path. They are removed.
    public mutating func due(now: Date) -> [URL] {
        let ready = lastEvent.filter { now.timeIntervalSince($0.value.at) >= quietPeriod }
        for key in ready.keys { lastEvent[key] = nil }
        return ready.sorted { $0.key < $1.key }.map(\.value.root)
    }
}
