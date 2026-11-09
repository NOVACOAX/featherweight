import Foundation

@testable import FeatherweightCore

/// Real-git fixtures for the git and cleaner tests. Never reads the user's global git config.
enum GitFixture {
    static let runner = ProcessCommandRunner(environment: [
        "PATH": "/usr/bin:/bin",
        "HOME": NSTemporaryDirectory(),
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
        "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
    ])

    @discardableResult
    static func git(_ args: [String], in directory: URL) throws -> String {
        let result = try runner.run(
            "/usr/bin/git", ["-c", "user.email=t@t", "-c", "user.name=t"] + args, in: directory)
        guard result.succeeded else {
            throw GitFixtureError.failed(args.joined(separator: " "), result.stderr)
        }
        return result.stdout
    }

    /// `git init` in `directory`, then add everything and commit.
    static func initRepo(_ directory: URL) throws {
        try git(["init", "-q", "-b", "main"], in: directory)
        try commitAll(directory)
    }

    static func commitAll(_ directory: URL, message: String = "init") throws {
        try git(["add", "-A"], in: directory)
        try git(["commit", "-q", "-m", message], in: directory)
    }
}

enum GitFixtureError: Error {
    case failed(String, String)
}
