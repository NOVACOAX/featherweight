import Foundation

public enum SkipReason: String, Codable, Sendable {
    case recentlyActive, trackedInGit, notEnabled
}

public struct CacheCandidate: Codable, Sendable, Hashable {
    public let projectRoot: String
    /// Absolute path of the cache folder.
    public let folder: String
    public let relativePath: String
    public let allocatedBytes: Int64
    public let skip: SkipReason?

    public init(
        projectRoot: String, folder: String, relativePath: String, allocatedBytes: Int64,
        skip: SkipReason?
    ) {
        self.projectRoot = projectRoot
        self.folder = folder
        self.relativePath = relativePath
        self.allocatedBytes = allocatedBytes
        self.skip = skip
    }
}

public struct CleanReport: Codable, Sendable, Equatable {
    /// Folders removed (or, for a dry run, folders that would be removed).
    public var cleared: [CacheCandidate]
    public var skipped: [CacheCandidate]
    public var bytesFreed: Int64
    public var errors: [String]

    public init(
        cleared: [CacheCandidate] = [], skipped: [CacheCandidate] = [], bytesFreed: Int64 = 0,
        errors: [String] = []
    ) {
        self.cleared = cleared
        self.skipped = skipped
        self.bytesFreed = bytesFreed
        self.errors = errors
    }
}

/// Finds and permanently removes build-cache folders. Folders tracked by git, folders in
/// recently active projects and disabled folders are never removed.
public struct CacheCleaner: Sendable {
    private let git: GitClient
    private let activity: ActivityChecker

    public init(git: GitClient, activity: ActivityChecker) {
        self.git = git
        self.activity = activity
    }

    /// Every configured cache folder that exists as a directory under each project root, with the
    /// reason it would be skipped, if any. Runs at background QoS; blocks until done, so call it
    /// off the main thread.
    public func plan(projects: [Project], settings: Settings) -> [CacheCandidate] {
        BackgroundWork.run { buildPlan(projects: projects, settings: settings) }
    }

    /// Removes every candidate with no skip reason. With `dryRun` nothing is deleted and the
    /// report describes what would have been. Blocks until done, so call it off the main thread.
    public func run(projects: [Project], settings: Settings, dryRun: Bool) -> CleanReport {
        BackgroundWork.run {
            var report = CleanReport()
            for candidate in buildPlan(projects: projects, settings: settings) {
                if candidate.skip != nil {
                    report.skipped.append(candidate)
                    continue
                }
                if !dryRun {
                    do {
                        try FileManager.default.removeItem(atPath: candidate.folder)
                    } catch {
                        report.errors.append("\(candidate.folder): \(error.localizedDescription)")
                        continue
                    }
                }
                report.cleared.append(candidate)
                report.bytesFreed += candidate.allocatedBytes
            }
            return report
        }
    }

    // MARK: - Planning

    private func buildPlan(projects: [Project], settings: Settings) -> [CacheCandidate] {
        let window = TimeInterval(settings.activityWindowHours) * 3600
        var candidates: [CacheCandidate] = []
        for project in projects {
            let projectPath = project.root.path
            var repoRoot: URL??  // computed lazily, once per project
            var active: Bool?  // likewise

            for setting in settings.cacheFolders {
                let folder = URL(fileURLWithPath: projectPath + "/" + setting.relativePath)
                guard Self.isRealDirectory(folder) else { continue }

                let skip: SkipReason?
                if !setting.enabled {
                    skip = .notEnabled
                } else {
                    if repoRoot == nil { repoRoot = .some(git.repoRoot(for: project.root)) }
                    if let root = repoRoot!, git.isTracked(folder, repoRoot: root) {
                        skip = .trackedInGit
                    } else {
                        if active == nil { active = activity.isActive(root: project.root, window: window) }
                        skip = active! ? .recentlyActive : nil
                    }
                }
                candidates.append(CacheCandidate(
                    projectRoot: projectPath,
                    folder: folder.path,
                    relativePath: setting.relativePath,
                    allocatedBytes: Self.allocatedBytes(of: folder),
                    skip: skip
                ))
            }
        }
        return candidates
    }

    /// A directory that is not a symlink (a symlinked cache folder is left alone).
    private static func isRealDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    private static func allocatedBytes(of folder: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys, options: []
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}
