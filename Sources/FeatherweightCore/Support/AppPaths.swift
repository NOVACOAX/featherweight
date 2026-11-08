import Foundation

/// Locations of every file Featherweight keeps on disk. Injectable so tests never touch the real state directory.
public struct AppPaths: Sendable {
    public let base: URL
    public let launchAgentsDir: URL
    public let home: URL

    public init(base: URL, launchAgentsDir: URL, home: URL) {
        self.base = base
        self.launchAgentsDir = launchAgentsDir
        self.home = home
    }

    public static let standard: AppPaths = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let library = home.appendingPathComponent("Library", isDirectory: true)
        return AppPaths(
            base: library
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("Featherweight", isDirectory: true),
            launchAgentsDir: library.appendingPathComponent("LaunchAgents", isDirectory: true),
            home: home
        )
    }()

    public var settings: URL { base.appendingPathComponent("settings.json") }
    public var history: URL { base.appendingPathComponent("history.jsonl") }
    public var stats: URL { base.appendingPathComponent("stats.json") }
    public var projects: URL { base.appendingPathComponent("projects.json") }
    public var hashCache: URL { base.appendingPathComponent("hashes.sqlite") }
    public var jobLock: URL { base.appendingPathComponent("jobs.lock") }
    public var helperPID: URL { base.appendingPathComponent("helper.pid") }
    public var backups: URL { base.appendingPathComponent("backups", isDirectory: true) }

    /// Creates the state directory and its `backups/` subdirectory if they are missing.
    public func ensureExists() throws {
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
    }
}
