import Foundation

/// Committing a finished conversion: the default message and which paths to stage.
public enum ConversionCommit {
    /// "Switch from npm to pnpm" or "Switch from yarn to pnpm".
    public static func defaultMessage(from manager: PackageManager) -> String {
        "Switch from \(manager.rawValue) to pnpm"
    }

    /// The changed files as paths relative to the repository, for a project at or below `repoRoot`.
    public static func repoPaths(_ changes: [FileChange], projectRoot: URL, repoRoot: URL) -> [String] {
        let project = PhysicalPath.resolve(projectRoot.path) ?? projectRoot.path
        let repo = PhysicalPath.resolve(repoRoot.path) ?? repoRoot.path
        let prefix: String
        if project == repo {
            prefix = ""
        } else if project.hasPrefix(repo.hasSuffix("/") ? repo : repo + "/") {
            prefix = String(project.dropFirst(repo.count).drop { $0 == "/" }) + "/"
        } else {
            prefix = ""
        }
        return changes.map { prefix + $0.relativePath }
    }
}
