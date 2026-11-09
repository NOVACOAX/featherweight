import Foundation

public struct NotificationText: Equatable, Sendable {
    public let title: String
    public let body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

/// Collects finished runs and turns them into at most one notification per `coalesceWindow`.
public struct NotificationComposer: Sendable {
    public let coalesceWindow: TimeInterval
    private var pending: [Entry] = []

    private struct Entry: Sendable {
        let record: RunRecord
        let projectName: String?
        let frequency: Schedule.Frequency
    }

    public init(coalesceWindow: TimeInterval = 300) {
        self.coalesceWindow = coalesceWindow
    }

    /// Queues `record` for the next notification. Runs that freed nothing without errors, and runs
    /// started from the app (which reports them itself), are dropped. `frequency` is the schedule
    /// of a scheduled run ("Weekly cleanup…"); by default the default schedules (daily dedupe,
    /// weekly clean). `projectName` names the project of an after-install run.
    public mutating func add(_ record: RunRecord, projectName: String?, frequency: Schedule.Frequency? = nil) {
        guard record.trigger != .manualApp, record.bytesFreed != 0 || !record.errors.isEmpty else { return }
        let defaultFrequency: Schedule.Frequency = record.kind == .clean ? .weekly : .daily
        pending.append(Entry(record: record, projectName: projectName, frequency: frequency ?? defaultFrequency))
    }

    /// When the pending runs may be flushed: `coalesceWindow` after the first one finished.
    public var nextFlush: Date? {
        pending.first.map { $0.record.finishedAt.addingTimeInterval(coalesceWindow) }
    }

    /// The notification for every pending run, once `coalesceWindow` has passed since the first
    /// one; nil before that or when nothing is pending. Returned runs are removed.
    public mutating func flush(now: Date) -> NotificationText? {
        guard let due = nextFlush, now >= due else { return nil }
        let entries = pending
        pending = []
        if let error = entries.lazy.compactMap(\.record.errors.first).first {
            return NotificationText(title: "Featherweight hit a problem", body: error)
        }
        let total = entries.reduce(Int64(0)) { $0 + $1.record.bytesFreed }
        let body = entries.count == 1
            ? Self.body(entries[0])
            : "Freed \(ByteFormat.string(total)) across \(entries.count) runs"
        return NotificationText(title: "Featherweight", body: body)
    }

    private static func body(_ entry: Entry) -> String {
        let freed = ByteFormat.string(entry.record.bytesFreed)
        let period = entry.frequency == .daily ? "Daily" : "Weekly"
        switch (entry.record.trigger, entry.record.kind) {
        case (.afterInstall, _):
            return entry.projectName.map { "Freed \(freed) after install in \($0)" } ?? "Freed \(freed) after install"
        case (.scheduled, .clean):
            return "\(period) cleanup freed \(freed)"
        case (.scheduled, .dedupe):
            return "\(period) sweep freed \(freed)"
        default:
            return "Freed \(freed)"
        }
    }
}
