import Foundation

public enum SkipReason: String, Codable, Sendable {
    case recentlyActive, trackedInGit, notEnabled
    /// Git could not say whether the folder is tracked (not the same as "not a repository"), so it
    /// is left alone; the cause is in `CleanReport.errors`.
    case gitUnavailable
    /// At removal time the folder was no longer a plain directory inside the project (it was
    /// replaced by a symlink, say).
    case pathChanged
    /// The folder contains a `.git` entry (a nested repository or submodule), whose tracking the
    /// cleaner does not inspect, so it is never removed.
    case containsRepository
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

extension CacheFolderSetting {
    /// True when `path` can safely name a cache folder inside a project: relative, no empty, `.`
    /// or `..` components (so it cannot reach the project root or anything outside it), no `.git`
    /// component, and not `node_modules` itself (only folders inside it). Names are compared
    /// case-insensitively and Unicode-normalised, because the default macOS volume treats `.GIT`
    /// as `.git`.
    public static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        if components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || isGitName($0) }) {
            return false
        }
        return foldedName(path) != "node_modules"
    }

    /// Case-folded, canonically normalised form of a file name, for comparing names the way a
    /// case-insensitive, normalisation-insensitive file system does.
    fileprivate static func foldedName<S: StringProtocol>(_ name: S) -> String {
        String(name).precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: nil)
    }

    fileprivate static func isGitName<S: StringProtocol>(_ name: S) -> Bool {
        foldedName(name) == ".git"
    }
}

/// Finds and permanently removes build-cache folders. Folders tracked by git, folders in
/// recently active projects, disabled folders and anything that is not provably a plain
/// directory inside the project are never removed.
public struct CacheCleaner: Sendable {
    private let git: GitClient
    private let activity: ActivityChecker
    /// Test seam: called after planning and before each removal is re-validated.
    private let beforeRemoval: @Sendable (CacheCandidate) -> Void

    public init(git: GitClient, activity: ActivityChecker) {
        self.init(git: git, activity: activity, beforeRemoval: { _ in })
    }

    init(
        git: GitClient, activity: ActivityChecker,
        beforeRemoval: @escaping @Sendable (CacheCandidate) -> Void
    ) {
        self.git = git
        self.activity = activity
        self.beforeRemoval = beforeRemoval
    }

    /// Every configured cache folder that exists as a directory under each project root, with the
    /// reason it would be skipped, if any. Runs at background QoS; blocks until done, so call it
    /// off the main thread.
    public func plan(projects: [Project], settings: Settings) -> [CacheCandidate] {
        BackgroundWork.run { buildPlan(projects: projects, settings: settings).entries.map(\.candidate) }
    }

    /// Removes every candidate with no skip reason. With `dryRun` nothing is deleted and the
    /// report describes what would have been. Each folder is re-validated (containment, git,
    /// activity) immediately before it is removed, because a project can become active, or a
    /// folder tracked, after planning. Blocks until done, so call it off the main thread.
    public func run(projects: [Project], settings: Settings, dryRun: Bool) -> CleanReport {
        BackgroundWork.run {
            var report = CleanReport()
            let plan = buildPlan(projects: projects, settings: settings)
            report.errors = plan.errors
            let window = Self.window(settings)
            for entry in plan.entries {
                var candidate = entry.candidate
                if candidate.skip == nil && !dryRun {
                    beforeRemoval(candidate)
                    var fresh = ProjectState()
                    switch evaluate(candidate, in: entry.project, window: window, state: &fresh) {
                    case .gitError(let error):
                        report.errors.append(error)
                        candidate = candidate.withSkip(.gitUnavailable)
                    case .skip(let skip):
                        candidate = candidate.withSkip(skip)
                    }
                }
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

    private struct Entry {
        let candidate: CacheCandidate
        let project: Project
    }

    /// Per-project facts that are expensive to compute, filled in lazily.
    private struct ProjectState {
        var repoRoot: URL??
        var active: Bool?
    }

    private static func window(_ settings: Settings) -> TimeInterval {
        TimeInterval(settings.activityWindowHours) * 3600
    }

    private func buildPlan(projects: [Project], settings: Settings) -> (entries: [Entry], errors: [String]) {
        let window = Self.window(settings)
        var entries: [Entry] = []
        var errors: [String] = []
        for setting in settings.cacheFolders where !CacheFolderSetting.isSafeRelativePath(setting.relativePath) {
            errors.append("Ignored unsafe cache folder path \"\(setting.relativePath)\"")
        }
        let valid = settings.cacheFolders.filter { CacheFolderSetting.isSafeRelativePath($0.relativePath) }
        for project in projects {
            var state = ProjectState()
            for setting in valid {
                let folder = URL(fileURLWithPath: project.root.path + "/" + setting.relativePath)
                guard Self.isPlainDirectoryInside(folder, relativePath: setting.relativePath, root: project.root)
                else { continue }
                var candidate = CacheCandidate(
                    projectRoot: project.root.path,
                    folder: folder.path,
                    relativePath: setting.relativePath,
                    allocatedBytes: Self.scan(folder).bytes,
                    skip: setting.enabled ? nil : .notEnabled
                )
                if setting.enabled {
                    switch evaluate(candidate, in: project, window: window, state: &state) {
                    case .skip(let skip): candidate = candidate.withSkip(skip)
                    case .gitError(let error):
                        errors.append(error)
                        candidate = candidate.withSkip(.gitUnavailable)
                    }
                }
                entries.append(Entry(candidate: candidate, project: project))
            }
        }
        return (entries, errors)
    }

    private enum Verdict {
        case skip(SkipReason?)
        /// Git failed; the candidate must be skipped and the message reported.
        case gitError(String)
    }

    /// Why an enabled candidate must be skipped, checked in order: containment, git, activity.
    private func evaluate(
        _ candidate: CacheCandidate, in project: Project, window: TimeInterval, state: inout ProjectState
    ) -> Verdict {
        let folder = URL(fileURLWithPath: candidate.folder)
        // Not provably a plain directory inside the project any more: leave it alone.
        guard Self.isPlainDirectoryInside(folder, relativePath: candidate.relativePath, root: project.root)
        else { return .skip(.pathChanged) }
        // A nested repository or submodule inside the folder: its tracking is not inspected.
        if Self.scan(folder).containsGit { return .skip(.containsRepository) }
        do {
            // Ask the project's repository and, when different, the innermost repository around
            // the folder (an independent repo between the project and the folder).
            if state.repoRoot == nil { state.repoRoot = .some(try git.findRepoRoot(for: project.root)) }
            let outer = state.repoRoot!
            let inner = try git.findRepoRoot(for: folder)
            for root in [outer, inner == outer ? nil : inner] {
                if let root, try git.checkTracked(folder, repoRoot: root) { return .skip(.trackedInGit) }
            }
        } catch {
            return .gitError("\(candidate.folder): git check failed, skipped (\(error))")
        }
        if state.active == nil { state.active = activity.isActive(root: project.root, window: window) }
        return .skip(state.active! ? .recentlyActive : nil)
    }

    /// A real directory (not a symlink) whose physical path is exactly the project's physical root
    /// plus `relativePath`: no component on the way down may be a symlink, so removing it cannot
    /// reach outside the project, and it can never be the project root.
    private static func isPlainDirectoryInside(_ folder: URL, relativePath: String, root: URL) -> Bool {
        guard CacheFolderSetting.isSafeRelativePath(relativePath) else { return false }
        let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true,
              let physicalFolder = PhysicalPath.resolve(folder.path),
              let physicalRoot = PhysicalPath.resolve(root.path)
        else { return false }
        // The root prefix must match exactly (a case-insensitive match could land in a different
        // directory on a case-sensitive volume). Only the part below the root is compared
        // case-insensitively, since the on-disk spelling may differ from the configured one.
        let prefix = physicalRoot.hasSuffix("/") ? physicalRoot : physicalRoot + "/"
        guard physicalFolder.hasPrefix(prefix) else { return false }
        let remainder = String(physicalFolder.dropFirst(prefix.count))
        return CacheFolderSetting.isSafeRelativePath(remainder)
            && CacheFolderSetting.foldedName(remainder) == CacheFolderSetting.foldedName(relativePath)
    }

    /// Allocated size of everything under `folder`, and whether any entry in it (file or
    /// directory, at any depth) is named `.git`. Symlinks are not followed.
    private static func scan(_ folder: URL) -> (bytes: Int64, containsGit: Bool) {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys, options: []
        ) else { return (0, false) }
        var total: Int64 = 0
        var containsGit = false
        for case let url as URL in enumerator {
            if CacheFolderSetting.isGitName(url.lastPathComponent) { containsGit = true }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return (total, containsGit)
    }
}

extension CacheCandidate {
    fileprivate func withSkip(_ skip: SkipReason?) -> CacheCandidate {
        CacheCandidate(
            projectRoot: projectRoot, folder: folder, relativePath: relativePath,
            allocatedBytes: allocatedBytes, skip: skip)
    }
}
