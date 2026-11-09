import Darwin
import Foundation
import Testing

@testable import FeatherweightCore

@Suite struct HelperHeartbeatTests {
    private func fixture(processName: String = "FeatherweightHelper") throws -> (TempTree, HelperHeartbeat) {
        let tree = try TempTree()
        let paths = AppPaths(base: tree.url("state"), launchAgentsDir: tree.url("LaunchAgents"), home: tree.root)
        return (tree, HelperHeartbeat(paths: paths, processName: processName))
    }

    /// Executable name of this test process.
    private var ownName: String {
        URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).lastPathComponent
    }

    @Test func heartbeatMissingFileIsNotAlive() throws {
        let (tree, heartbeat) = try fixture()
        defer { tree.remove() }

        #expect(!heartbeat.isAlive())
    }

    @Test func heartbeatAliveForRunningHelperProcess() throws {
        let (tree, heartbeat) = try fixture(processName: ownName)
        defer { tree.remove() }

        try heartbeat.write(pid: getpid())

        #expect(heartbeat.isAlive())
    }

    @Test func heartbeatNotAliveWhenPidIsAnotherProgram() throws {
        let (tree, heartbeat) = try fixture()
        defer { tree.remove() }

        // A running process, but not FeatherweightHelper (for example a reused pid).
        try heartbeat.write(pid: getpid())

        #expect(!heartbeat.isAlive())
    }

    @Test func heartbeatNotAliveForExitedProcess() throws {
        let (tree, heartbeat) = try fixture(processName: "true")
        defer { tree.remove() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()

        try heartbeat.write(pid: process.processIdentifier)

        #expect(!heartbeat.isAlive())
    }
}
