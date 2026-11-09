import Darwin
import Foundation
import Testing

@testable import FeatherweightCore

@Suite struct HelperHeartbeatTests {
    private func fixture() throws -> (TempTree, HelperHeartbeat) {
        let tree = try TempTree()
        let paths = AppPaths(base: tree.url("state"), launchAgentsDir: tree.url("LaunchAgents"), home: tree.root)
        return (tree, HelperHeartbeat(paths: paths))
    }

    @Test func heartbeatAliveForRunningProcess() throws {
        let (tree, heartbeat) = try fixture()
        defer { tree.remove() }
        #expect(!heartbeat.isAlive())

        try heartbeat.write(pid: getpid())

        #expect(heartbeat.isAlive())
    }

    @Test func heartbeatNotAliveForExitedProcess() throws {
        let (tree, heartbeat) = try fixture()
        defer { tree.remove() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()

        try heartbeat.write(pid: process.processIdentifier)

        #expect(!heartbeat.isAlive())
    }
}
