import Foundation

/// One row of `projects.json`, the app's per-project list.
public struct ProjectSummary: Codable, Sendable, Identifiable {
    /// The project's root path.
    public let id: String
    public let name: String
    public let parentRoot: String?
    public let packageManager: PackageManager
    /// Logical size of `node_modules`.
    public let nodeModulesBytes: Int64
    public let sharedBytes: Int64
    public let cacheBytes: Int64
    public let lastActive: Date?
    /// One of "Up to date", "Cleared X", "Skipped: active", ".output kept", "Tracked in git",
    /// "Linked by pnpm" (plus "Git unavailable", "Skipped" and "<name> kept" for other cases).
    public let status: String
    public let gitBranch: String?
    public let upstream: String?
    public let remoteURL: String?

    public init(
        id: String, name: String, parentRoot: String?, packageManager: PackageManager,
        nodeModulesBytes: Int64, sharedBytes: Int64, cacheBytes: Int64, lastActive: Date?,
        status: String, gitBranch: String?, upstream: String?, remoteURL: String?
    ) {
        self.id = id
        self.name = name
        self.parentRoot = parentRoot
        self.packageManager = packageManager
        self.nodeModulesBytes = nodeModulesBytes
        self.sharedBytes = sharedBytes
        self.cacheBytes = cacheBytes
        self.lastActive = lastActive
        self.status = status
        self.gitBranch = gitBranch
        self.upstream = upstream
        self.remoteURL = remoteURL
    }

    /// The single place that turns a project's state into its status string.
    ///
    /// - Parameters:
    ///   - candidates: the project's cache folders as the cleaner would treat them now.
    ///   - clearedByLastClean: the most recent clean run cleared this project.
    ///   - clearedBytes: how much that run cleared, when known (it is not stored in history).
    ///
    /// Precedence: pnpm projects are always "Linked by pnpm"; then anything that stops a cache
    /// being cleared (active, tracked in git, git unavailable, changed path or nested
    /// repository); then "Cleared X"; then a disabled cache folder that was left alone; else
    /// "Up to date".
    static func status(
        packageManager: PackageManager, candidates: [CacheCandidate], clearedByLastClean: Bool,
        clearedBytes: Int64?
    ) -> String {
        if packageManager == .pnpm { return "Linked by pnpm" }
        let reasons = Set(candidates.compactMap(\.skip))
        if reasons.contains(.recentlyActive) { return "Skipped: active" }
        if reasons.contains(.trackedInGit) { return "Tracked in git" }
        if reasons.contains(.gitUnavailable) { return "Git unavailable" }
        if reasons.contains(.pathChanged) || reasons.contains(.containsRepository) { return "Skipped" }
        if clearedByLastClean {
            return "Cleared " + (clearedBytes.map(ByteFormat.string) ?? "caches")
        }
        if let kept = candidates.first(where: { $0.skip == .notEnabled }) {
            return "\(kept.relativePath) kept"
        }
        return "Up to date"
    }
}
