import Foundation

public enum GitError: Error, Equatable {
    case commandFailed(command: String, exitCode: Int32, stderr: String)
    /// A path handed to `commit` that could stage more than the one file it names.
    case invalidPathspec(String)
}

/// Thin wrapper over `/usr/bin/git` (run as `env LC_ALL=C git ...`). Every call passes paths as separate arguments (never through
/// a shell) and puts `--` before pathspecs. Pathspecs are literal, so names containing glob
/// characters or spaces mean exactly what they say.
public struct GitClient: Sendable {
    private static let git = "/usr/bin/git"
    private static let env = "/usr/bin/env"

    private let runner: CommandRunner

    public init(runner: CommandRunner) {
        self.runner = runner
    }

    /// Top-level directory of the work tree containing `directory`, or nil outside a repository.
    /// Best effort: any git failure also reads as nil. Code that deletes things must use
    /// `findRepoRoot(for:)`, which tells "not a repository" apart from a git error.
    public func repoRoot(for directory: URL) -> URL? {
        try? findRepoRoot(for: directory)
    }

    /// True when git tracks `path` itself or, for a directory, anything beneath it. Best effort:
    /// any git failure reads as false. Deleting code must use `checkTracked(_:repoRoot:)`.
    public func isTracked(_ path: URL, repoRoot: URL) -> Bool {
        (try? checkTracked(path, repoRoot: repoRoot)) ?? false
    }

    /// Like `repoRoot(for:)`, but returns nil only when `directory` is genuinely not inside a git
    /// repository. Any other failure (git missing, "dubious ownership", a locked index) throws.
    public func findRepoRoot(for directory: URL) throws -> URL? {
        let args = ["rev-parse", "--show-toplevel"]
        let result = try exec(args, in: directory)
        if !result.succeeded {
            // The full "(or any of the parent directories)" message only: a dangling `.git` file
            // says just "not a git repository: <path>", and that is an error, not "no repo".
            if result.exitCode == 128
                && result.stderr.contains("not a git repository (or any of the parent directories)") {
                return nil
            }
            throw Self.failure(args, result)
        }
        // Trim only line endings: a path may legitimately end in a space.
        let text = result.stdout.trimmingCharacters(in: .newlines)
        guard !text.isEmpty else { throw Self.failure(args, result) }  // success with no path: fail closed
        // Git prints the physical path (`/private/var/...`); canonicalise it the same way project
        // roots are, so the two compare equal.
        return URL(fileURLWithPath: text, isDirectory: true).resolvingSymlinksInPath()
    }

    /// Like `isTracked(_:repoRoot:)`, but throws on any git failure (including a path outside the
    /// repository) instead of answering false.
    public func checkTracked(_ path: URL, repoRoot: URL) throws -> Bool {
        guard let relative = Self.relativePath(of: path, in: repoRoot) else {
            throw GitError.invalidPathspec(path.path)
        }
        let args = ["--literal-pathspecs", "ls-files", "-z", "--", relative]
        let result = try exec(args, in: repoRoot)
        guard result.succeeded else { throw Self.failure(args, result) }
        return !result.stdout.isEmpty
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
    /// Anything else that is modified or staged is left alone, so a path that is empty, absolute,
    /// the repo root itself or contains a `..` component is rejected rather than staged.
    public func commit(files: [String], message: String, repoRoot: URL) throws {
        guard !files.isEmpty else { return }
        for file in files where !Self.isSafePathspec(file) {
            throw GitError.invalidPathspec(file)
        }
        try runChecked(["--literal-pathspecs", "add", "-A", "--"] + files, in: repoRoot)
        try runChecked(["--literal-pathspecs", "commit", "-m", message, "--"] + files, in: repoRoot)
    }

    /// Pushes the current branch. A rejected push is reported through the result, not thrown.
    /// `GIT_TERMINAL_PROMPT=0` makes git fail instead of waiting for a credential prompt; it is
    /// set through `env` because the runner's environment is fixed when it is created.
    public func push(repoRoot: URL) throws -> CommandResult {
        try exec(["push"], in: repoRoot, extraEnvironment: ["GIT_TERMINAL_PROMPT=0"])
    }

    // MARK: - Helpers

    /// Runs git through `/usr/bin/env` so each call gets its own environment (the runner's is
    /// fixed when it is created). `LC_ALL=C` keeps git's messages in English, which the
    /// "not a git repository" check depends on, whatever the user's locale.
    private func exec(
        _ args: [String], in directory: URL, extraEnvironment: [String] = []
    ) throws -> CommandResult {
        try runner.run(
            Self.env, ["LC_ALL=C"] + extraEnvironment + [Self.git] + args, in: directory)
    }

    /// Trimmed-of-newline stdout of a successful, non-empty command; nil otherwise.
    private func output(_ args: [String], in directory: URL) -> String? {
        guard let result = try? exec(args, in: directory), result.succeeded else {
            return nil
        }
        // Trim only line endings: a path may legitimately end in a space.
        let text = result.stdout.trimmingCharacters(in: .newlines)
        return text.isEmpty ? nil : text
    }

    private func runChecked(_ args: [String], in directory: URL) throws {
        let result = try exec(args, in: directory)
        guard result.succeeded else { throw Self.failure(args, result) }
    }

    private static func failure(_ args: [String], _ result: CommandResult) -> GitError {
        .commandFailed(
            command: "git " + args.joined(separator: " "), exitCode: result.exitCode,
            stderr: result.stderr)
    }

    private static func isSafePathspec(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        return !components.isEmpty && !components.contains { $0 == "." || $0 == ".." }
    }

    /// Physical path; for a path that does not exist, the physical parent plus the last component.
    private static func physicalPath(_ path: String) -> String {
        if let resolved = PhysicalPath.resolve(path) { return resolved }
        let url = URL(fileURLWithPath: path)
        guard let parent = PhysicalPath.resolve(url.deletingLastPathComponent().path) else { return path }
        return (parent.hasSuffix("/") ? parent : parent + "/") + url.lastPathComponent
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
