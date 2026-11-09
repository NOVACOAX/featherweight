import Foundation
import Testing

@testable import FeatherweightCore

@Suite struct HistoryTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func record(
        _ kind: JobKind, bytes: Int64, finished: Date, summary: String = "s"
    ) -> RunRecord {
        RunRecord(
            id: UUID(), kind: kind, trigger: .manualCLI,
            startedAt: finished.addingTimeInterval(-5), finishedAt: finished,
            bytesFreed: bytes, summary: summary, projects: ["/p"], skipped: [], errors: [],
            lastFSEventID: 42)
    }

    private func store(_ tree: TempTree) -> HistoryStore {
        HistoryStore(url: tree.url("state/history.jsonl"))
    }

    @Test func historyAppendAndReadNewestFirst() throws {
        let tree = try TempTree()
        defer { tree.remove() }
        let history = store(tree)
        let first = record(.dedupe, bytes: 1, finished: date(2026, 11, 1))
        let second = record(.clean, bytes: 2, finished: date(2026, 11, 2))
        try history.append(first)
        try history.append(second)

        #expect(history.all() == [second, first])
        #expect(history.lastRun(of: .dedupe) == first)
        #expect(history.lastRun(of: .clean) == second)
        #expect(history.lastRun(of: .convert) == nil)
    }

    @Test func historySkipsCorruptLine() throws {
        let tree = try TempTree()
        defer { tree.remove() }
        let history = store(tree)
        let first = record(.dedupe, bytes: 1, finished: date(2026, 11, 1))
        let second = record(.clean, bytes: 2, finished: date(2026, 11, 2))
        try history.append(first)
        let handle = try FileHandle(forWritingTo: tree.url("state/history.jsonl"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{ this is not json\n\n".utf8))
        try handle.close()
        try history.append(second)

        #expect(history.all() == [second, first])
    }

    @Test func historyOfMissingFileIsEmpty() throws {
        let tree = try TempTree()
        defer { tree.remove() }
        #expect(store(tree).all().isEmpty)
    }

    @Test func cachesClearedThisMonthSumsOnlyCleanThisMonth() throws {
        let tree = try TempTree()
        defer { tree.remove() }
        let history = store(tree)
        try history.append(record(.clean, bytes: 100, finished: date(2026, 11, 2)))
        try history.append(record(.clean, bytes: 50, finished: date(2026, 11, 8)))
        try history.append(record(.dedupe, bytes: 1_000, finished: date(2026, 11, 3)))
        try history.append(record(.clean, bytes: 7_000, finished: date(2026, 10, 31, 23)))
        try history.append(record(.clean, bytes: 9_000, finished: date(2025, 11, 5)))

        #expect(history.cachesClearedThisMonth(now: date(2026, 11, 9), calendar: calendar) == 150)
    }

    @Test func unterminatedLastLineDoesNotSwallowNextRecord() throws {
        let tree = try TempTree()
        defer { tree.remove() }
        let history = store(tree)
        let first = record(.dedupe, bytes: 1, finished: date(2026, 11, 1))
        let second = record(.clean, bytes: 2, finished: date(2026, 11, 2))
        try history.append(first)
        // Simulate a crash mid-write: a partial record with no trailing newline.
        let handle = try FileHandle(forWritingTo: tree.url("state/history.jsonl"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"id\":\"partial".utf8))
        try handle.close()
        try history.append(second)

        #expect(history.all() == [second, first])
    }

    @Test func appendsFromSeparateStoresAllLand() throws {
        let tree = try TempTree()
        defer { tree.remove() }
        let url = tree.url("state/history.jsonl")
        let records = (0..<200).map { record(.clean, bytes: Int64($0), finished: date(2026, 11, 1)) }

        DispatchQueue.concurrentPerform(iterations: records.count) { i in
            // A fresh store per append, as separate processes would have.
            try? HistoryStore(url: url).append(records[i])
        }

        let stored = HistoryStore(url: url).all()
        #expect(stored.count == records.count)
        #expect(Set(stored.map(\.id)) == Set(records.map(\.id)))
    }

    @Test func appendNeverTruncatesAnExistingFile() throws {
        let tree = try TempTree()
        defer { tree.remove() }
        let history = store(tree)
        for i in 0..<3 { try history.append(record(.clean, bytes: Int64(i), finished: date(2026, 11, 1))) }
        try HistoryStore(url: tree.url("state/history.jsonl"))
            .append(record(.dedupe, bytes: 9, finished: date(2026, 11, 2)))

        #expect(history.all().count == 4)
    }
}
