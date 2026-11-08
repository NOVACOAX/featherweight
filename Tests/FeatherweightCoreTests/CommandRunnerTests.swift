import Foundation
import Testing
@testable import FeatherweightCore

struct CommandRunnerTests {
    @Test func runnerResolvesBareCommandOnPath() throws {
        let runner = ProcessCommandRunner(environment: ["PATH": "/usr/bin:/bin"])
        let result = try runner.run("echo", ["hi"], in: nil)
        #expect(result.stdout == "hi\n")
        #expect(result.exitCode == 0)
        #expect(result.succeeded)
    }

    @Test func runnerAcceptsAbsolutePath() throws {
        let runner = ProcessCommandRunner(environment: ["PATH": ""])
        let result = try runner.run("/bin/echo", ["abs"], in: nil)
        #expect(result.stdout == "abs\n")
    }

    @Test func runnerReportsFailureExitCodeAndStderr() throws {
        let runner = ProcessCommandRunner(environment: ["PATH": "/usr/bin:/bin"])
        let result = try runner.run("sh", ["-c", "echo oops >&2; exit 3"], in: nil)
        #expect(result.exitCode == 3)
        #expect(result.stderr == "oops\n")
        #expect(!result.succeeded)
    }

    @Test func runnerRunsInDirectoryWithSpacesAndUnicode() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lightroom \(UUID().uuidString) café", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let runner = ProcessCommandRunner(environment: ["PATH": "/usr/bin:/bin"])
        let result = try runner.run("pwd", [], in: directory)
        let printed = result.stdout.trimmingCharacters(in: .newlines)
        #expect(URL(fileURLWithPath: printed).resolvingSymlinksInPath()
            == directory.resolvingSymlinksInPath())
    }

    @Test func runnerHandlesOutputLargerThanPipeBuffer() throws {
        let runner = ProcessCommandRunner(environment: ["PATH": "/usr/bin:/bin"])
        let result = try runner.run("sh", ["-c", "head -c 300000 /dev/zero | tr '\\0' 'a'"], in: nil)
        #expect(result.stdout.count == 300_000)
    }

    @Test func runnerThrowsWhenCommandIsNotOnPath() {
        let runner = ProcessCommandRunner(environment: ["PATH": "/usr/bin:/bin"])
        #expect(throws: CommandRunnerError.self) {
            try runner.run("definitely-not-a-real-command", [], in: nil)
        }
    }

    @Test func loginShellEnvironmentFallsBack() {
        let environment = LoginShellEnvironment.resolve(shell: "/nonexistent", timeout: 1)
        #expect(environment["PATH"] != nil)
    }

    @Test func loginShellEnvironmentIncludesShellPath() {
        let environment = LoginShellEnvironment.resolve(shell: "/bin/zsh", timeout: 10)
        #expect(!(environment["PATH"] ?? "").isEmpty)
    }
}
