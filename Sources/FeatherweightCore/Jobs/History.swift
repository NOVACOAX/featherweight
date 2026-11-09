import Darwin
import Foundation

public enum JobKind: String, Codable, Sendable {
    case dedupe, clean, convert, revert
}

public enum JobTrigger: String, Codable, Sendable {
    case scheduled, afterInstall, manualApp, manualCLI, firstLaunch
}

/// One finished job. Stored as a single JSON line in `history.jsonl` (default `JSONEncoder` coding).
public struct RunRecord: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let kind: JobKind
    public let trigger: JobTrigger
    public let startedAt: Date
    public let finishedAt: Date
    public let bytesFreed: Int64
    public let summary: String
    public let projects: [String]
    public let skipped: [String]
    public let errors: [String]
    /// File-system event ID current when the job finished; the helper ignores events at or below it.
    public let lastFSEventID: UInt64

    public init(
        id: UUID, kind: JobKind, trigger: JobTrigger, startedAt: Date, finishedAt: Date,
        bytesFreed: Int64, summary: String, projects: [String], skipped: [String],
        errors: [String], lastFSEventID: UInt64
    ) {
        self.id = id
        self.kind = kind
        self.trigger = trigger
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.bytesFreed = bytesFreed
        self.summary = summary
        self.projects = projects
        self.skipped = skipped
        self.errors = errors
        self.lastFSEventID = lastFSEventID
    }
}

/// Append-only JSON-lines log of finished jobs.
public final class HistoryStore: Sendable {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Appends one JSON line, creating the file and its folder if needed.
    ///
    /// The file is opened `O_APPEND` and the line goes out in a single `write(2)`, so concurrent
    /// appends from several processes land whole, one after another. If a crash left the last
    /// line unterminated, the new record starts on a fresh line so it stays readable.
    public func append(_ record: RunRecord) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var line = try encoder.encode(record)
        line.append(UInt8(ascii: "\n"))
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        if Self.endsWithPartialLine(fd) { line.insert(UInt8(ascii: "\n"), at: 0) }
        let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == line.count else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// True when the file is non-empty and its last byte is not a newline.
    private static func endsWithPartialLine(_ fd: Int32) -> Bool {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > 0 else { return false }
        var last: UInt8 = 0
        guard pread(fd, &last, 1, info.st_size - 1) == 1 else { return false }
        return last != UInt8(ascii: "\n")
    }

    /// Every readable record, newest first. Corrupt lines are skipped.
    public func all() -> [RunRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n"))
            .compactMap { try? decoder.decode(RunRecord.self, from: Data($0)) }
            .reversed()
    }

    public func lastRun(of kind: JobKind) -> RunRecord? {
        all().first { $0.kind == kind }
    }

    /// Total bytes freed by cache cleans that finished in the same calendar month as `now`.
    public func cachesClearedThisMonth(now: Date, calendar: Calendar) -> Int64 {
        all()
            .filter { $0.kind == .clean && calendar.isDate($0.finishedAt, equalTo: now, toGranularity: .month) }
            .reduce(0) { $0 + $1.bytesFreed }
    }
}
