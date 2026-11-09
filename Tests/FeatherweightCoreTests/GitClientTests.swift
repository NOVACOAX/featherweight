import Foundation
import Testing

@testable import FeatherweightCore

@Suite struct GitClientTests {
    private let client = GitClient(runner: GitFixture.runner)

    @Test func isTrackedDetectsCommittedFolder() throws {
        let tree = try TempTree(["app/.cache/keep.txt": "x", "app/src/a.ts": "a"])
        defer { tree.remove() }
        try GitFixture.initRepo(tree.root)
        try tree.add(["app/.next/page.js": "y"])

        let repo = try #require(client.repoRoot(for: tree.url("app")))
        #expect(client.isTracked(tree.url("app/.cache"), repoRoot: repo))
        #expect(!client.isTracked(tree.url("app/.next"), repoRoot: repo))
    }

    @Test func repoRootIsNilOutsideRepository() throws {
        let tree = try TempTree(["a.txt": "a"])
        defer { tree.remove() }
        #expect(client.repoRoot(for: tree.root) == nil)
    }

    @Test func repoRootFromSubdirectory() throws {
        let tree = try TempTree(["sub/deep/a.txt": "a"])
        defer { tree.remove() }
        try GitFixture.initRepo(tree.root)
        let repo = try #require(client.repoRoot(for: tree.url("sub/deep")))
        #expect(repo.path == tree.root.path)
    }

    @Test func commitStagesOnlyListedFiles() throws {
        let tree = try TempTree(["a.txt": "1", "b.txt": "1"])
        defer { tree.remove() }
        try GitFixture.initRepo(tree.root)
        try tree.add(["a.txt": "2", "b.txt": "2"])

        try client.commit(files: ["a.txt"], message: "only a", repoRoot: tree.root)

        let status = try GitFixture.git(["status", "--porcelain"], in: tree.root)
        #expect(status.contains("b.txt"))
        #expect(!status.contains("a.txt"))
        let subject = try GitFixture.git(["log", "-1", "--format=%s"], in: tree.root)
        #expect(subject.trimmingCharacters(in: .newlines) == "only a")
    }

    @Test func commitIncludesDeletion() throws {
        let tree = try TempTree(["package-lock.json": "{}", "package.json": "{}"])
        defer { tree.remove() }
        try GitFixture.initRepo(tree.root)
        try FileManager.default.removeItem(at: tree.url("package-lock.json"))

        try client.commit(files: ["package-lock.json"], message: "drop lock", repoRoot: tree.root)

        let files = try GitFixture.git(["ls-tree", "-r", "--name-only", "HEAD"], in: tree.root)
        #expect(!files.contains("package-lock.json"))
        #expect(files.contains("package.json"))
    }

    @Test func commitDoesNotSweepUpOtherStagedFiles() throws {
        let tree = try TempTree(["a.txt": "1", "b.txt": "1"])
        defer { tree.remove() }
        try GitFixture.initRepo(tree.root)
        try tree.add(["a.txt": "2", "b.txt": "2"])
        try GitFixture.git(["add", "b.txt"], in: tree.root)

        try client.commit(files: ["a.txt"], message: "only a", repoRoot: tree.root)

        let committed = try GitFixture.git(["show", "--name-only", "--format=", "HEAD"], in: tree.root)
        #expect(committed.contains("a.txt"))
        #expect(!committed.contains("b.txt"))
    }

    @Test func commitThrowsWhenGitFails() throws {
        let tree = try TempTree(["a.txt": "1"])
        defer { tree.remove() }
        // Not a repository, so add fails.
        #expect(throws: GitError.self) {
            try client.commit(files: ["a.txt"], message: "m", repoRoot: tree.root)
        }
    }

    @Test func upstreamNilWithoutRemote() throws {
        let tree = try TempTree(["a.txt": "1"])
        defer { tree.remove() }
        try GitFixture.initRepo(tree.root)
        #expect(client.upstream(tree.root) == nil)
        #expect(client.remoteURL(tree.root, remote: "origin") == nil)
        #expect(client.currentBranch(tree.root) == "main")
    }

    @Test func upstreamAndRemoteURLWithRemote() throws {
        let origin = try TempTree()
        let tree = try TempTree(["a.txt": "1"])
        defer { origin.remove(); tree.remove() }
        try GitFixture.git(["init", "-q", "--bare", "-b", "main"], in: origin.root)
        try GitFixture.initRepo(tree.root)
        try GitFixture.git(["remote", "add", "origin", origin.root.path], in: tree.root)
        try GitFixture.git(["push", "-q", "-u", "origin", "main"], in: tree.root)

        #expect(client.upstream(tree.root) == "origin/main")
        #expect(client.remoteURL(tree.root, remote: "origin") == origin.root.path)

        try tree.add(["a.txt": "2"])
        try client.commit(files: ["a.txt"], message: "two", repoRoot: tree.root)
        let result = try client.push(repoRoot: tree.root)
        #expect(result.succeeded)
    }

    @Test(arguments: ["", ".", "..", "../x", "a/../b", "/etc/passwd", "a/.", "./"])
    func commitRejectsPathspecsThatCouldStageMoreThanOneFile(path: String) throws {
        let tree = try TempTree(["a.txt": "1", "b.txt": "1"])
        defer { tree.remove() }
        try GitFixture.initRepo(tree.root)
        try tree.add(["a.txt": "2", "b.txt": "2"])

        #expect(throws: GitError.invalidPathspec(path)) {
            try client.commit(files: ["a.txt", path], message: "nope", repoRoot: tree.root)
        }

        // Rejected before anything ran: no commit, nothing staged.
        let count = try GitFixture.git(["rev-list", "--count", "HEAD"], in: tree.root)
        #expect(count.trimmingCharacters(in: .newlines) == "1")
        let staged = try GitFixture.git(["diff", "--cached", "--name-only"], in: tree.root)
        #expect(staged.isEmpty)
    }

    @Test func pushDisablesCredentialPrompts() throws {
        let seen = CallLog()
        let runner = FakeRunner { command, args in
            seen.append(([command] + args).joined(separator: " "))
            return CommandResult(exitCode: 0, stdout: "", stderr: "")
        }
        _ = try GitClient(runner: runner).push(repoRoot: URL(fileURLWithPath: "/tmp"))
        #expect(seen.all == [GitClientTests.envPrefix + "LC_ALL=C GIT_TERMINAL_PROMPT=0 /usr/bin/git push"])
    }

    @Test func findRepoRootDistinguishesNotARepoFromGitErrors() throws {
        let notRepo = FakeRunner { _, _ in
            CommandResult(exitCode: 128, stdout: "", stderr: "fatal: not a git repository (or any of the parent directories): .git\n")
        }
        #expect(try GitClient(runner: notRepo).findRepoRoot(for: URL(fileURLWithPath: "/tmp")) == nil)

        let broken = FakeRunner { _, _ in
            CommandResult(exitCode: 128, stdout: "", stderr: "fatal: detected dubious ownership in repository")
        }
        #expect(throws: GitError.self) {
            try GitClient(runner: broken).findRepoRoot(for: URL(fileURLWithPath: "/tmp"))
        }
        // The best-effort wrapper still answers nil.
        #expect(GitClient(runner: broken).repoRoot(for: URL(fileURLWithPath: "/tmp")) == nil)
    }

    /// Every git call starts with this: inherited variables that would cut discovery short or point
    /// git at another repository or index are removed.
    static let envPrefix =
        "/usr/bin/env -u GIT_CEILING_DIRECTORIES -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR "

    @Test func everyGitCallRunsWithACleanEnvironmentAndLocaleForcedToC() throws {
        let tree = try TempTree()
        defer { tree.remove() }
        let seen = CallLog()
        let runner = FakeRunner { command, args in
            seen.append(([command] + args).joined(separator: " "))
            return CommandResult(exitCode: 0, stdout: tree.root.path + "\n", stderr: "")
        }
        let client = GitClient(runner: runner)
        let dir = tree.root
        _ = try client.findRepoRoot(for: dir)
        _ = try client.checkTracked(dir.appendingPathComponent("x"), repoRoot: dir)
        _ = client.currentBranch(dir)
        _ = client.upstream(dir)
        _ = client.remoteURL(dir, remote: "origin")
        try client.commit(files: ["a"], message: "m", repoRoot: dir)
        _ = try client.push(repoRoot: dir)
        #expect(seen.all.count >= 8)
        for call in seen.all {
            #expect(call.hasPrefix(Self.envPrefix + "LC_ALL=C "), "\(call)")
            #expect(call.contains(" /usr/bin/git "), "\(call)")
        }
    }

    @Test func findRepoRootDiscoversAcrossFileSystemBoundaries() throws {
        let tree = try TempTree()
        defer { tree.remove() }
        let seen = CallLog()
        let runner = FakeRunner { command, args in
            seen.append(([command] + args).joined(separator: " "))
            return CommandResult(exitCode: 0, stdout: tree.root.path + "\n", stderr: "")
        }
        _ = try GitClient(runner: runner).findRepoRoot(for: tree.root)
        #expect(seen.all == [
            Self.envPrefix + "LC_ALL=C GIT_DISCOVERY_ACROSS_FILESYSTEM=1 /usr/bin/git rev-parse --show-toplevel"
        ])
    }

    @Test func inheritedGitVariablesDoNotCutDiscoveryShortOrRedirectIt() throws {
        let tree = try TempTree(["repo/sub/.next/keep.txt": "k", "other/a.txt": "a"])
        defer { tree.remove() }
        let repo = tree.url("repo")
        try GitFixture.initRepo(repo)  // commits sub/.next/keep.txt
        try GitFixture.initRepo(tree.url("other"))  // an unrelated repository that tracks nothing here
        let runner = ProcessCommandRunner(environment: [
            "PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory(),
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CEILING_DIRECTORIES": repo.path,
            "GIT_DIR": tree.url("other/.git").path,
            "GIT_WORK_TREE": tree.url("other").path,
            "GIT_INDEX_FILE": tree.url("other/.git/index").path,
            "GIT_COMMON_DIR": tree.url("other/.git").path,
        ])
        let client = GitClient(runner: runner)
        let root = try #require(try client.findRepoRoot(for: tree.url("repo/sub")))
        #expect(PhysicalPath.resolve(root.path) == PhysicalPath.resolve(repo.path))
        #expect(try client.checkTracked(tree.url("repo/sub/.next"), repoRoot: root))
    }

    @Test func notARepositoryIsDetectedUnderNonEnglishParentLocale() throws {
        let tree = try TempTree(["a.txt": "1"])
        defer { tree.remove() }
        // The parent environment asks for German; the client must still get English messages.
        let runner = ProcessCommandRunner(environment: [
            "PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory(),
            "LANG": "de_DE.UTF-8", "LC_ALL": "de_DE.UTF-8", "LANGUAGE": "de",
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
        ])
        let client = GitClient(runner: runner)
        #expect(try client.findRepoRoot(for: tree.root) == nil)
    }

    @Test func successfulRevParseWithNoOutputFailsClosed() throws {
        let tree = try TempTree()
        defer { tree.remove() }
        let empty = FakeRunner { _, _ in CommandResult(exitCode: 0, stdout: "\n", stderr: "") }
        #expect(throws: GitError.self) { try GitClient(runner: empty).findRepoRoot(for: tree.root) }
    }

    @Test func danglingGitFileThrowsInsteadOfReportingNoRepository() throws {
        let tree = try TempTree([".git": "gitdir: /nonexistent/moved/repo\n", "a.txt": "1"])
        defer { tree.remove() }
        #expect(throws: GitError.self) { try GitClient(runner: GitFixture.runner).findRepoRoot(for: tree.root) }
    }

    @Test func notARepositoryMessageWithoutParentDirectoriesSuffixIsAnError() throws {
        let tree = try TempTree()
        defer { tree.remove() }
        let runner = FakeRunner { _, _ in
            CommandResult(exitCode: 128, stdout: "", stderr: "fatal: not a git repository: (null)")
        }
        #expect(throws: GitError.self) { try GitClient(runner: runner).findRepoRoot(for: tree.root) }
    }

    @Test func stoppingAtAMountPointCountsAsNoRepository() throws {
        let tree = try TempTree()
        defer { tree.remove() }
        let runner = FakeRunner { _, _ in
            CommandResult(
                exitCode: 128, stdout: "",
                stderr: "fatal: not a git repository (or any parent up to mount point /Volumes/Ext)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n")
        }
        #expect(try GitClient(runner: runner).findRepoRoot(for: tree.root) == nil)
    }

    @Test func mountPointMessageWithoutTheBoundaryLineIsAnError() throws {
        let tree = try TempTree()
        defer { tree.remove() }
        let runner = FakeRunner { _, _ in
            CommandResult(exitCode: 128, stdout: "", stderr: "fatal: not a git repository (or any parent up to mount point /Volumes/Ext)\n")
        }
        #expect(throws: GitError.self) { try GitClient(runner: runner).findRepoRoot(for: tree.root) }
    }

    @Test func checkTrackedThrowsOnGitFailure() throws {
        let tree = try TempTree(["a.txt": "1"])
        defer { tree.remove() }
        let broken = FakeRunner { _, _ in CommandResult(exitCode: 128, stdout: "", stderr: "fatal: boom") }
        #expect(throws: GitError.self) {
            try GitClient(runner: broken).checkTracked(tree.url("a.txt"), repoRoot: tree.root)
        }
    }
}

final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}
