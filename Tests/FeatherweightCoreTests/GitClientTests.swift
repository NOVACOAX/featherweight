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
}
