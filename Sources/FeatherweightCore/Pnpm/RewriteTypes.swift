import Foundation

/// A reference to npm or yarn that the rewriter could not change with certainty.
public struct RewriteWarning: Codable, Sendable, Hashable {
    /// Path relative to the project root.
    public let file: String
    /// 1-based line number.
    public let line: Int
    public let text: String

    public init(file: String, line: Int, text: String) {
        self.file = file
        self.line = line
        self.text = text
    }
}

/// The proposed new contents of one project file.
public struct FileRewrite: Sendable {
    public let relativePath: String
    public let original: String
    public let rewritten: String
    public let warnings: [RewriteWarning]

    public var changed: Bool { rewritten != original }

    public init(relativePath: String, original: String, rewritten: String, warnings: [RewriteWarning]) {
        self.relativePath = relativePath
        self.original = original
        self.rewritten = rewritten
        self.warnings = warnings
    }
}

/// Rewrites npm or yarn references in a project's configs to pnpm. Must not write anything:
/// the converter applies the rewrites itself, after backing the files up.
public protocol ConfigRewriting: Sendable {
    func rewriteProject(root: URL, from: PackageManager, pnpmVersion: String) throws -> [FileRewrite]
}
