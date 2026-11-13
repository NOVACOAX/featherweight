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

    /// `standard`, unless the environment's `FEATHERWEIGHT_STATE_DIR` names a folder to keep all
    /// state in (development and testing of the CLI and helper only). With that override the
    /// "home" is the same folder, so the default project folder (`~/Developer`) is never picked up
    /// by accident.
    public static func resolved(environment: [String: String]) -> AppPaths {
        guard let override = environment["FEATHERWEIGHT_STATE_DIR"], !override.isEmpty else { return .standard }
        let base = URL(fileURLWithPath: override, isDirectory: true)
        return AppPaths(
            base: base, launchAgentsDir: base.appendingPathComponent("LaunchAgents", isDirectory: true),
            home: base)
    }

    public var settings: URL { base.appendingPathComponent("settings.json") }
    public var history: URL { base.appendingPathComponent("history.jsonl") }
    public var stats: URL { base.appendingPathComponent("stats.json") }
    public var appState: URL { base.appendingPathComponent("state.json") }
    public var projects: URL { base.appendingPathComponent("projects.json") }
    public var hashCache: URL { base.appendingPathComponent("hashes.sqlite") }
    /// Each project's latest node_modules tally, so jobs re-walk only the projects they touched.
    public var tallies: URL { base.appendingPathComponent("tallies.sqlite") }
    public var jobLock: URL { base.appendingPathComponent("jobs.lock") }
    public var helperPID: URL { base.appendingPathComponent("helper.pid") }
    public var backups: URL { base.appendingPathComponent("backups", isDirectory: true) }

    /// Creates the state directory and its `backups/` subdirectory if they are missing.
    public func ensureExists() throws {
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
    }
}
