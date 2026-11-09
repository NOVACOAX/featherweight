import Foundation
import Testing
@testable import FeatherweightCore

@Suite struct SavingsMeterTests {
    @Test func meterCountsSharedBytes() throws {
        let f = try DedupeFixture()
        defer { f.tree.remove() }
        _ = f.deduper().run(projects: f.projects, dryRun: false)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let snapshot = SavingsMeter().measure(projects: f.projects, now: now)

        #expect(abs(snapshot.sharedBytes - 65536) <= 4096)
        // Credited to the non-first member in path order: b, not a.
        #expect(snapshot.perProject == [f.root("b"): snapshot.sharedBytes])
        #expect(snapshot.measuredAt == now)
    }

    @Test func meterZeroBeforeRun() throws {
        let f = try DedupeFixture()
        defer { f.tree.remove() }

        let snapshot = SavingsMeter().measure(projects: f.projects, now: Date())

        #expect(snapshot.sharedBytes == 0)
        #expect(snapshot.perProject.isEmpty)
    }

    @Test func meterIgnoresQuietPeriod() throws {
        let f = try DedupeFixture()
        defer { f.tree.remove() }
        _ = f.deduper().run(projects: f.projects, dryRun: false)
        try f.tree.setAllMTimes(to: Date())

        let snapshot = SavingsMeter().measure(projects: f.projects, now: Date())

        #expect(abs(snapshot.sharedBytes - 65536) <= 4096)
    }
}
