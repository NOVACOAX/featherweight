import Foundation
import Testing
@testable import FeatherweightCore

struct DuplicateEstimateTests {
    @Test func countsTheSamePackageFileAcrossProjectsOnce() throws {
        let fixture = try DedupeFixture(["a", "b", "c"])
        let bytes = DuplicateEstimate.bytes(projects: fixture.projects)
        // Three copies of react/index.js (64 KiB) save two; unique and empty files save nothing.
        #expect(abs(bytes - 2 * 65_536) <= 3 * 4_096)
    }

    @Test func matchesWhatARealSweepFrees() throws {
        let fixture = try DedupeFixture()
        let estimate = DuplicateEstimate.bytes(projects: fixture.projects)
        let real = fixture.deduper().run(projects: fixture.projects, dryRun: true).bytesFreed
        #expect(abs(estimate - real) <= 4_096)
    }

    @Test func filesAlreadySharingBlocksCountOnce() throws {
        let fixture = try DedupeFixture()
        _ = fixture.deduper().run(projects: fixture.projects, dryRun: false)
        #expect(DuplicateEstimate.bytes(projects: fixture.projects) == 0)
    }

    @Test func readsThePathInsideTheInnermostNodeModules() {
        #expect(DuplicateEstimate.packagePath(of: "/p/node_modules/a/node_modules/b/index.js") == "b/index.js")
        #expect(DuplicateEstimate.packagePath(of: "/p/src/index.js") == nil)
    }
}
