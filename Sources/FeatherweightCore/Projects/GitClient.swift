import Foundation

public enum GitError: Error, Equatable {
    case commandFailed(command: String, exitCode: Int32, stderr: String)
}

/// Thin wrapper over `/usr/bin/git`. Every call passes paths as separate arguments (never through
/// a shell) and puts `--` before pathspecs. Pathspecs are literal, so names containing glob
/// characters or spaces mean exactly what they say.
public struct GitClient: Sendable {
    private static let git = "/usr/bin/git"

    private let runner: CommandRunner

    public init(runner: CommandRunner) {
        self.runner = runner
    }

    /// Top-level directory of the work tree containing `directory`, or nil outside a repository.
    public func repoRoot(for directory: URL) -> URL? {
        guard let output = output(["rev-parse", "--show-toplevel"], in: directory) else { return nil }
        // Git prints the physical path (`/private/var/...`); canonicalise it the same way project
        // roots are, so the two compare equal.
        return URL(fileURLWithPath: output, isDirectory: true).resolvingSymlinksInPath()
    }

    /// True when git tracks `path` itself or, for a directory, anything beneath it.
    public func isTracked(_ path: URL, repoRoot: URL) -> Bool {
        guard let relative = Self.relativePath(of: path, in: repoRoot) else { return false }
        guard let result = try? runner.run(
            Self.git, ["--literal-pathspecs", "ls-files", "-z", "--", relative], in: repoRoot
        ) else { return false }
        return result.succeeded && !result.stdout.isEmpty
    }

    public func currentBranch(_ root: URL) -> String? {
        output(["branch", "--show-current"], in: root)
    }

    /// The configured upstream of the current branch, such as `origin/main`.
    public func upstream(_ root: URL) -> String? {
        output(["rev-parse", "--abbrev-ref", "@{u}"], in: root)
    }

    public func remoteURL(_ root: URL, remote: String) -> String? {
        output(["remote", "get-url", remote], in: root)
    }

    /// Stages and commits exactly `files` (paths relative to `repoRoot`, deletions included).
    /// Anything else that is modified or staged is left alone.
    public func commit(files: [String], message: String, repoRoot: URL) throws {
        guard !files.isEmpty else { return }
        try runChecked(["--literal-pathspecs", "add", "-A", "--"] + files, in: repoRoot)
        try runChecked(["--literal-pathspecs", "commit", "-m", message, "--"] + files, in: repoRoot)
    }

    /// Pushes the current branch. A rejected push is reported through the result, not thrown.
    public func push(repoRoot: URL) throws -> CommandResult {
        try runner.run(Self.git, ["push"], in: repoRoot)
    }

    // MARK: - Helpers

    /// Trimmed-of-newline stdout of a successful, non-empty command; nil otherwise.
    private func output(_ args: [String], in directory: URL) -> String? {
        guard let result = try? runner.run(Self.git, args, in: directory), result.succeeded else {
            return nil
        }
        // Trim only line endings: a path may legitimately end in a space.
        let text = result.stdout.trimmingCharacters(in: .newlines)
        return text.isEmpty ? nil : text
    }

    private func runChecked(_ args: [String], in directory: URL) throws {
        let result = try runner.run(Self.git, args, in: directory)
        guard result.succeeded else {
            throw GitError.commandFailed(
                command: "git " + args.joined(separator: " "),
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
    }

    /// Path with every symlink resolved (so `/var` and `/private/var` compare equal).
    private static func physicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// `path` relative to `root`, or nil if it lies outside it. The root itself is ".".
    static func relativePath(of path: URL, in root: URL) -> String? {
        let full = physicalPath(path.path)
        let base = physicalPath(root.path)
        if full == base { return "." }
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard full.hasPrefix(prefix) else { return nil }
        return String(full.dropFirst(prefix.count))
    }
}
