import Foundation
import SQLite3

/// What one walk of a project's `node_modules` found, kept so later jobs that don't touch the
/// project can reuse it instead of walking it again.
struct ProjectTally {
    struct CloneKey: Hashable {
        let device: UInt64
        let cloneID: UInt64
    }

    /// The project's files in one APFS clone group: how many, their allocated sizes summed, and
    /// the allocated size of the member that comes first in path order.
    struct Group {
        var count: Int64
        var sizeSum: Int64
        var firstPath: String
        var firstSize: Int64
    }

    var logicalBytes: Int64 = 0
    var groups: [CloneKey: Group] = [:]
}

extension SavingsMeter {
    /// Walks one project's `node_modules`. Only the non-empty, single-link files that share all
    /// their blocks join a group, as in `measure`.
    static func tally(_ project: Project) -> ProjectTally {
        var tally = ProjectTally()
        NodeModulesFiles.forEach(in: [project], onError: { _ in }) { file in
            let info = file.info
            tally.logicalBytes += info.size
            guard NodeModulesFiles.isCandidate(info), info.sharesAllBlocks, info.cloneID != 0 else { return }
            let key = ProjectTally.CloneKey(device: info.device, cloneID: info.cloneID)
            let path = file.url.path
            if var group = tally.groups[key] {
                group.count += 1
                group.sizeSum += info.allocatedSize
                if path < group.firstPath {
                    group.firstPath = path
                    group.firstSize = info.allocatedSize
                }
                tally.groups[key] = group
            } else {
                tally.groups[key] = ProjectTally.Group(
                    count: 1, sizeSum: info.allocatedSize, firstPath: path, firstSize: info.allocatedSize)
            }
        }
        return tally
    }

    /// Indices of the projects whose `node_modules` a full walk visits: the ones not equal to or
    /// inside another's (whose files the outer project already counts), as in `NodeModulesFiles`.
    static func outermost(_ projects: [Project]) -> [Int] {
        let roots = projects.enumerated()
            .compactMap { index, project in project.nodeModules.map { (index, $0.path) } }
            .sorted { $0.1 < $1.1 }
        var visited: [String] = []
        var indices: [Int] = []
        for (index, path) in roots where !visited.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            visited.append(path)
            indices.append(index)
        }
        return indices
    }
}

public enum SavingsTallyError: Error {
    case sqlite(String, Int32, String)
}

/// Every project's latest `ProjectTally`, in SQLite. Combining them gives exactly what one walk of
/// all projects gives: no two walked `node_modules` folders nest, so which project holds a clone
/// group's first member (in path order) is decided by the folders' own paths.
final class SavingsTallyStore {
    private var db: OpaquePointer?

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw SavingsTallyError.sqlite("open", rc, message)
        }
        db = handle
        do {
            sqlite3_busy_timeout(handle, 5000)
            try exec("PRAGMA journal_mode=WAL")
            try exec("PRAGMA synchronous=NORMAL")
            // Rows name their project by a small integer, not its path, to keep the file small.
            try exec("""
                CREATE TABLE IF NOT EXISTS projects(
                    id INTEGER PRIMARY KEY, root TEXT NOT NULL UNIQUE, folder TEXT NOT NULL, logical INTEGER NOT NULL
                )
                """)
            try exec("""
                CREATE TABLE IF NOT EXISTS clone_groups(
                    project INTEGER NOT NULL, device INTEGER NOT NULL, clone INTEGER NOT NULL,
                    count INTEGER NOT NULL, size_sum INTEGER NOT NULL, first_size INTEGER NOT NULL,
                    PRIMARY KEY(project, device, clone)
                ) WITHOUT ROWID
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

    /// Project root → the `node_modules` path its stored tally was walked from.
    func measuredFolders() throws -> [String: String] {
        let statement = try prepare("SELECT root, folder FROM projects")
        defer { sqlite3_finalize(statement) }
        var folders: [String: String] = [:]
        while try step(statement, "read projects") {
            folders[text(statement, 0)] = text(statement, 1)
        }
        return folders
    }

    /// Replaces the stored tally of the project at `root`.
    func replace(root: String, folder: String, with tally: ProjectTally) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            let project = try prepare("""
                INSERT INTO projects(root, folder, logical) VALUES(?, ?, ?)
                ON CONFLICT(root) DO UPDATE SET folder = excluded.folder, logical = excluded.logical
                RETURNING id
                """)
            defer { sqlite3_finalize(project) }
            try bind(project, 1, root)
            try bind(project, 2, folder)
            sqlite3_bind_int64(project, 3, tally.logicalBytes)
            guard try step(project, "store project") else { throw failure("store project", SQLITE_ERROR) }
            let id = sqlite3_column_int64(project, 0)
            _ = try step(project, "store project")

            let clear = try prepare("DELETE FROM clone_groups WHERE project = ?")
            defer { sqlite3_finalize(clear) }
            sqlite3_bind_int64(clear, 1, id)
            try done(clear, "clear")

            let insert = try prepare("""
                INSERT INTO clone_groups(project, device, clone, count, size_sum, first_size) VALUES(?, ?, ?, ?, ?, ?)
                """)
            defer { sqlite3_finalize(insert) }
            for (key, group) in tally.groups {
                sqlite3_reset(insert)
                sqlite3_bind_int64(insert, 1, id)
                sqlite3_bind_int64(insert, 2, Int64(bitPattern: key.device))
                sqlite3_bind_int64(insert, 3, Int64(bitPattern: key.cloneID))
                sqlite3_bind_int64(insert, 4, group.count)
                sqlite3_bind_int64(insert, 5, group.sizeSum)
                sqlite3_bind_int64(insert, 6, group.firstSize)
                try done(insert, "store group")
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Deletes the tallies of every project not in `roots`.
    func retain(roots: Set<String>) throws {
        for root in try measuredFolders().keys where !roots.contains(root) {
            for sql in [
                "DELETE FROM clone_groups WHERE project = (SELECT id FROM projects WHERE root = ?)",
                "DELETE FROM projects WHERE root = ?",
            ] {
                let statement = try prepare(sql)
                defer { sqlite3_finalize(statement) }
                try bind(statement, 1, root)
                try done(statement, "retain")
            }
        }
    }

    /// The savings snapshot and each project's logical size (by index into `projects`), from the
    /// stored tallies of the projects at `included` (the outermost ones, all stored).
    func combine(projects: [Project], included: [Int], now: Date) throws -> (snapshot: SavingsSnapshot, logicalBytes: [Int64]) {
        try exec("CREATE TEMP TABLE IF NOT EXISTS ranks(project INTEGER PRIMARY KEY, root TEXT NOT NULL, rank INTEGER NOT NULL)")
        try exec("DELETE FROM ranks")
        // A project's files all sort together, in the order of their `node_modules` paths.
        let ordered = included.sorted { projects[$0].nodeModules!.path + "/" < projects[$1].nodeModules!.path + "/" }
        let rank = try prepare("INSERT INTO ranks(project, root, rank) SELECT id, root, ? FROM projects WHERE root = ?")
        for (position, index) in ordered.enumerated() {
            sqlite3_reset(rank)
            sqlite3_bind_int64(rank, 1, Int64(position))
            try bind(rank, 2, projects[index].root.path)
            try done(rank, "rank")
        }
        sqlite3_finalize(rank)

        var logical = [Int64](repeating: 0, count: projects.count)
        let indexByRoot = Dictionary(included.map { (projects[$0].root.path, $0) }, uniquingKeysWith: { first, _ in first })
        let sizes = try prepare("SELECT p.root, p.logical FROM projects p JOIN ranks r ON r.project = p.id")
        defer { sqlite3_finalize(sizes) }
        while try step(sizes, "read sizes") {
            if let index = indexByRoot[text(sizes, 0)] { logical[index] = sqlite3_column_int64(sizes, 1) }
        }

        // Every member of a group with more than one member is credited, except the first in
        // path order, which is the first member of the lowest-ranked project holding the group.
        let credits = try prepare("""
            WITH members AS (
                SELECT r.root, g.device, g.clone, g.count, g.size_sum, g.first_size, r.rank
                FROM clone_groups g JOIN ranks r ON r.project = g.project
            ), shared AS (
                SELECT device, clone, MIN(rank) AS first_rank FROM members
                GROUP BY device, clone HAVING SUM(count) > 1
            )
            SELECT m.root, SUM(m.size_sum - CASE WHEN m.rank = s.first_rank THEN m.first_size ELSE 0 END)
            FROM members m JOIN shared s ON s.device = m.device AND s.clone = m.clone
            GROUP BY m.root
            """)
        defer { sqlite3_finalize(credits) }
        var snapshot = SavingsSnapshot(measuredAt: now)
        while try step(credits, "combine") {
            let bytes = sqlite3_column_int64(credits, 1)
            guard bytes > 0 else { continue }
            snapshot.perProject[text(credits, 0)] = bytes
            snapshot.sharedBytes += bytes
        }
        return (snapshot, logical)
    }

    // MARK: - SQLite

    private func exec(_ sql: String) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        while try step(statement, "exec") {}
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard rc == SQLITE_OK, let statement else { throw failure("prepare", rc) }
        return statement
    }

    /// True while a row is available.
    private func step(_ statement: OpaquePointer, _ what: String) throws -> Bool {
        let rc = sqlite3_step(statement)
        if rc == SQLITE_ROW { return true }
        guard rc == SQLITE_DONE else { throw failure(what, rc) }
        return false
    }

    private func done(_ statement: OpaquePointer, _ what: String) throws {
        _ = try step(statement, what)
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String) throws {
        let rc = sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard rc == SQLITE_OK else { throw failure("bind", rc) }
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    private func failure(_ what: String, _ code: Int32) -> SavingsTallyError {
        .sqlite(what, code, db.map { String(cString: sqlite3_errmsg($0)) } ?? "no connection")
    }
}
