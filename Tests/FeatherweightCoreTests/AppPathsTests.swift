import Foundation
import Testing

@testable import FeatherweightCore

@Suite struct AppPathsTests {
    @Test func resolvedUsesStandardPathsWithoutOverride() {
        #expect(AppPaths.resolved(environment: [:]).base == AppPaths.standard.base)
        #expect(AppPaths.resolved(environment: ["FEATHERWEIGHT_STATE_DIR": ""]).base == AppPaths.standard.base)
    }

    @Test func resolvedKeepsEverythingInTheOverrideFolder() {
        let paths = AppPaths.resolved(environment: ["FEATHERWEIGHT_STATE_DIR": "/tmp/fw state"])

        #expect(paths.base.path == "/tmp/fw state")
        #expect(paths.home.path == "/tmp/fw state")
        #expect(paths.launchAgentsDir.path == "/tmp/fw state/LaunchAgents")
    }
}
