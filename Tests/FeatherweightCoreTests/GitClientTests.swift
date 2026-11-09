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
        #expect(seen.all == ["/usr/bin/env LC_ALL=C GIT_TERMINAL_PROMPT=0 /usr/bin/git push"])
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

    @Test func everyGitCallRunsWithLocaleForcedToC() throws {
        let seen = CallLog()
        let runner = FakeRunner { command, args in
            seen.append(([command] + args).joined(separator: " "))
            return CommandResult(exitCode: 0, stdout: "/tmp\n", stderr: "")
        }
        let client = GitClient(runner: runner)
        let dir = URL(fileURLWithPath: "/tmp")
        _ = try client.findRepoRoot(for: dir)
        _ = try client.checkTracked(dir.appendingPathComponent("x"), repoRoot: dir)
        _ = client.currentBranch(dir)
        _ = client.upstream(dir)
        _ = client.remoteURL(dir, remote: "origin")
        try client.commit(files: ["a"], message: "m", repoRoot: dir)
        _ = try client.push(repoRoot: dir)
        #expect(seen.all.count >= 8)
        for call in seen.all {
            #expect(call.hasPrefix("/usr/bin/env LC_ALL=C /usr/bin/git ") || call.hasPrefix("/usr/bin/env LC_ALL=C GIT_TERMINAL_PROMPT=0 /usr/bin/git "), "\(call)")
        }
    }

    @Test func notARepositoryIsDetectedUnderNonEnglishParentLocale() throws {
        let tree = try TempTree(["a.txt": "1"])
        defer { tree.remove() }
        // The parent environment asks for German; the client must still get English messages.
        let runner = ProcessCommandRunner(environment: [
            "PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory(),
            "LANG": "de_DE.UTF-8", "LC_ALL": "de_DE.UTF-8", "LANGUAGE": "de",
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CEILING_DIRECTORIES": tree.root.deletingLastPathComponent().path,
        ])
        let client = GitClient(runner: runner)
        #expect(try client.findRepoRoot(for: tree.root) == nil)
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
