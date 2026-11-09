import CryptoKit
import Foundation
import SQLite3

public enum HashCacheError: Error {
    /// A failed SQLite call: what was being done, the SQLite result code and its message.
    case sqlite(String, Int32, String)
}

/// Persistent SHA-256 cache keyed by path and validated by inode, size and mtime.
///
/// Safe to open from several processes (WAL plus a busy timeout) and to call from several threads
/// (one lock serializes all access to the connection).
public final class HashCache: @unchecked Sendable {
    private static let chunkSize = 1 << 20
    private static let busyTimeoutMillis: Int32 = 5000

    private let lock = NSLock()
    private var db: OpaquePointer?
    private var computed = 0

    /// Number of digests computed (cache misses) by this instance. For tests.
    public var hashesComputed: Int {
        lock.lock()
        defer { lock.unlock() }
        return computed
    }

    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(
            url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw HashCacheError.sqlite("open", rc, message)
        }
        db = handle
        do {
            sqlite3_busy_timeout(handle, Self.busyTimeoutMillis)
            try exec("PRAGMA journal_mode=WAL")
            // Safe for a cache under WAL: a crash may lose recent rows, never corrupt the file.
            try exec("PRAGMA synchronous=NORMAL")
            try exec("""
                CREATE TABLE IF NOT EXISTS hashes(
                    path TEXT PRIMARY KEY,
                    inode INTEGER,
                    size INTEGER,
                    mtime INTEGER,
                    digest BLOB
                )
                """)
        } catch {
            sqlite3_close(handle)
            db = nil
            throw error
        }
    }

    deinit {
        sqlite3_close(db)
    }

    /// Returns the SHA-256 of the file at `url`. A cached digest is used when the stored inode,
    /// size and mtime equal `info`; otherwise the file is streamed in 1 MB chunks and the result
    /// is stored.
    public func digest(for url: URL, info: CloneInfo) throws -> Data {
        lock.lock()
        defer { lock.unlock() }

        let path = url.path
        let inode = Int64(bitPattern: info.inode)
        if let cached = try lookup(path: path, inode: inode, size: info.size, mtime: info.mtimeNanos) {
            return cached
        }

        let digest = try Self.sha256(of: url)
        computed += 1
        try store(path: path, inode: inode, size: info.size, mtime: info.mtimeNanos, digest: digest)
        return digest
    }

    /// Deletes every entry whose path does not start with one of `prefixes`.
    /// Prefixes are raw string prefixes, so callers should include the trailing "/"
    /// (otherwise "/a/b" also keeps "/a/b2/...").
    public func prune(keepingPathsWithPrefixes prefixes: [String]) throws {
        lock.lock()
        defer { lock.unlock() }

        // Prefixes are compared with substr(), not LIKE, so `%` and `_` in paths stay literal.
        let clause = Array(repeating: "substr(path, 1, length(?)) = ?", count: prefixes.count)
            .joined(separator: " OR ")
        let sql = prefixes.isEmpty
            ? "DELETE FROM hashes"
            : "DELETE FROM hashes WHERE NOT (\(clause))"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (index, prefix) in prefixes.enumerated() {
            try bindText(statement, Int32(index * 2 + 1), prefix)
            try bindText(statement, Int32(index * 2 + 2), prefix)
        }
        try stepDone(statement, "prune")
    }

    // MARK: - Hashing

    private static func sha256(of url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        // Each chunk is autoreleased by Foundation; drain per iteration so a large file does not
        // accumulate in memory.
        var reachedEnd = false
        while !reachedEnd {
            try autoreleasepool {
                guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                    reachedEnd = true
                    return
                }
                hasher.update(data: chunk)
            }
        }
        return Data(hasher.finalize())
    }

    // MARK: - SQLite

    private func lookup(path: String, inode: Int64, size: Int64, mtime: Int64) throws -> Data? {
        let statement = try prepare("SELECT inode, size, mtime, digest FROM hashes WHERE path = ?")
        defer { sqlite3_finalize(statement) }
        try bindText(statement, 1, path)
        let rc = sqlite3_step(statement)
        if rc == SQLITE_DONE { return nil }
        guard rc == SQLITE_ROW else { throw error("lookup", rc) }
        guard sqlite3_column_int64(statement, 0) == inode,
              sqlite3_column_int64(statement, 1) == size,
              sqlite3_column_int64(statement, 2) == mtime,
              let bytes = sqlite3_column_blob(statement, 3) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 3)))
    }

    private func store(path: String, inode: Int64, size: Int64, mtime: Int64, digest: Data) throws {
        let statement = try prepare("""
            INSERT INTO hashes(path, inode, size, mtime, digest) VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET
                inode = excluded.inode, size = excluded.size,
                mtime = excluded.mtime, digest = excluded.digest
            """)
        defer { sqlite3_finalize(statement) }
        try bindText(statement, 1, path)
        sqlite3_bind_int64(statement, 2, inode)
        sqlite3_bind_int64(statement, 3, size)
        sqlite3_bind_int64(statement, 4, mtime)
        let rc = digest.withUnsafeBytes { raw in
            sqlite3_bind_blob(statement, 5, raw.baseAddress, Int32(raw.count), Self.transient)
        }
        guard rc == SQLITE_OK else { throw error("bind", rc) }
        try stepDone(statement, "store")
    }

    private func exec(_ sql: String) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var rc = sqlite3_step(statement)
        while rc == SQLITE_ROW { rc = sqlite3_step(statement) }
        guard rc == SQLITE_DONE else { throw error("exec", rc) }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard rc == SQLITE_OK, let statement else { throw error("prepare", rc) }
        return statement
    }

    private func bindText(_ statement: OpaquePointer, _ index: Int32, _ value: String) throws {
        let rc = sqlite3_bind_text(statement, index, value, -1, Self.transient)
        guard rc == SQLITE_OK else { throw error("bind", rc) }
    }

    private func stepDone(_ statement: OpaquePointer, _ what: String) throws {
        let rc = sqlite3_step(statement)
        guard rc == SQLITE_DONE else { throw error(what, rc) }
    }

    private func error(_ what: String, _ code: Int32) -> HashCacheError {
        .sqlite(what, code, db.map { String(cString: sqlite3_errmsg($0)) } ?? "no connection")
    }

    /// SQLITE_TRANSIENT: tells SQLite to copy bound bytes before the call returns.
    private static var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }
}
