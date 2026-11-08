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

    @Test func runnerReturnsWhenBackgroundProcessHoldsThePipes() throws {
        let runner = ProcessCommandRunner(environment: ["PATH": "/usr/bin:/bin"])
        let started = Date()
        let result = try runner.run("sh", ["-c", "sleep 10 & echo done"], in: nil)
        #expect(result.stdout == "done\n")
        #expect(result.succeeded)
        #expect(Date().timeIntervalSince(started) < 8)
    }

    /// Writes an executable script to stand in for the login shell. It ignores the `-ilc` arguments.
    private func makeFakeShell(_ body: String) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("featherweight-shell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("fake-shell")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }

    @Test func loginShellEnvironmentParsesMarkerAndNulSeparatedEntries() throws {
        let shell = try makeFakeShell(
            #"printf 'rc noise\nmore noise\n__FW__PATH=/custom\0EMPTY=\0WITH_EQUALS=a=b\0HOME=/home/x\0'"#
        )
        let environment = LoginShellEnvironment.resolve(shell: shell, timeout: 10)
        #expect(environment == [
            "PATH": "/custom", "EMPTY": "", "WITH_EQUALS": "a=b", "HOME": "/home/x",
        ])
    }

    @Test func loginShellEnvironmentFallsBackWhenOutputHasNoPath() throws {
        let shell = try makeFakeShell(#"printf '__FW__HOME=/home/x\0'"#)
        let environment = LoginShellEnvironment.resolve(shell: shell, timeout: 10)
        #expect(environment == ProcessInfo.processInfo.environment)
    }

    @Test func loginShellEnvironmentFallsBackWhenShellFails() throws {
        let shell = try makeFakeShell(#"printf '__FW__PATH=/custom\0'; exit 1"#)
        let environment = LoginShellEnvironment.resolve(shell: shell, timeout: 10)
        #expect(environment == ProcessInfo.processInfo.environment)
    }

    @Test func loginShellEnvironmentFallsBackPromptlyOnTimeout() throws {
        let shell = try makeFakeShell("exec sleep 30")
        let started = Date()
        let environment = LoginShellEnvironment.resolve(shell: shell, timeout: 1)
        #expect(environment == ProcessInfo.processInfo.environment)
        #expect(Date().timeIntervalSince(started) < 5)
    }
}
