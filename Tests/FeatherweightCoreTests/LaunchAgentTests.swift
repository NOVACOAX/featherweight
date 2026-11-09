import Darwin
import Foundation
import Testing

@testable import FeatherweightCore

/// Records every command instead of running it; `bootstrap` fails when `failBootstrap` is set.
private final class RecordingRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    let failBootout: Bool
    let failBootstrap: Bool

    init(failBootout: Bool = false, failBootstrap: Bool = false) {
        self.failBootout = failBootout
        self.failBootstrap = failBootstrap
    }

    var commands: [[String]] { lock.withLock { recorded } }

    func run(_ command: String, _ args: [String], in directory: URL?) throws -> CommandResult {
        lock.withLock { recorded.append([command] + args) }
        if args.first == "bootout", failBootout {
            return CommandResult(exitCode: 3, stdout: "", stderr: "No such process")
        }
        if args.first == "bootstrap", failBootstrap {
            return CommandResult(exitCode: 5, stdout: "", stderr: "Bootstrap failed: 5: Input/output error")
        }
        return CommandResult(exitCode: 0, stdout: "", stderr: "")
    }
}

@Suite struct LaunchAgentTests {
    private let label = "com.novacoax.featherweight.helper"
    private let helper = URL(fileURLWithPath: "/Applications/Featherweight.app/Contents/Helpers/FeatherweightHelper")

    private func fixture() throws -> (TempTree, AppPaths) {
        let tree = try TempTree()
        let paths = AppPaths(base: tree.url("state"), launchAgentsDir: tree.url("LaunchAgents"), home: tree.root)
        return (tree, paths)
    }

    @Test func plistHasBackgroundKeys() throws {
        let (tree, paths) = try fixture()
        defer { tree.remove() }
        let plist = LaunchAgent(paths: paths, runner: RecordingRunner()).plist(helperExecutable: helper)

        #expect(LaunchAgent.label == label)
        #expect(plist["Label"] as? String == label)
        #expect(plist["ProgramArguments"] as? [String] == [helper.path])
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["KeepAlive"] as? [String: Bool] == ["SuccessfulExit": false])
        #expect(plist["ProcessType"] as? String == "Background")
        #expect(plist["LowPriorityIO"] as? Bool == true)
        #expect(plist["LowPriorityBackgroundIO"] as? Bool == true)
        #expect(plist["Nice"] as? Int == 10)
        #expect(plist.count == 8)
    }

    @Test func installWritesPlistThenBootsOutAndBootstraps() throws {
        let (tree, paths) = try fixture()
        defer { tree.remove() }
        let runner = RecordingRunner(failBootout: true)
        let agent = LaunchAgent(paths: paths, runner: runner)
        #expect(!agent.isInstalled())

        try agent.install(helperExecutable: helper)

        let plistURL = paths.launchAgentsDir.appendingPathComponent("\(label).plist")
        let written = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: plistURL), format: nil) as? [String: Any]
        #expect(written?["Label"] as? String == label)
        #expect(written?["ProgramArguments"] as? [String] == [helper.path])
        #expect(written?["Nice"] as? Int == 10)
        let domain = "gui/\(getuid())"
        #expect(runner.commands == [
            ["/bin/launchctl", "bootout", "\(domain)/\(label)"],
            ["/bin/launchctl", "bootstrap", domain, plistURL.path],
        ])
        #expect(agent.isInstalled())
    }

    @Test func installThrowsWhenBootstrapFails() throws {
        let (tree, paths) = try fixture()
        defer { tree.remove() }
        let agent = LaunchAgent(paths: paths, runner: RecordingRunner(failBootstrap: true))

        #expect(throws: LaunchAgentError.self) { try agent.install(helperExecutable: helper) }
    }

    @Test func uninstallBootsOutAndRemovesPlist() throws {
        let (tree, paths) = try fixture()
        defer { tree.remove() }
        try LaunchAgent(paths: paths, runner: RecordingRunner()).install(helperExecutable: helper)
        let runner = RecordingRunner(failBootout: true)
        let agent = LaunchAgent(paths: paths, runner: runner)

        try HelperHeartbeat(paths: paths).write(pid: 12345)

        try agent.uninstall()

        #expect(runner.commands == [["/bin/launchctl", "bootout", "gui/\(getuid())/\(label)"]])
        #expect(!agent.isInstalled())
        #expect(!FileManager.default.fileExists(atPath: paths.helperPID.path))
        // Uninstalling again is harmless.
        try agent.uninstall()
    }
}
