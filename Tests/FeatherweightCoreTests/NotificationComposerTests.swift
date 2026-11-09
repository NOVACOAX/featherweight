import Foundation
import Testing

@testable import FeatherweightCore

@Suite struct NotificationComposerTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func record(
        _ kind: JobKind, _ trigger: JobTrigger, bytes: Int64, errors: [String] = [], at offset: TimeInterval = 0
    ) -> RunRecord {
        RunRecord(
            id: UUID(), kind: kind, trigger: trigger, startedAt: t0.addingTimeInterval(offset),
            finishedAt: t0.addingTimeInterval(offset), bytesFreed: bytes, summary: "", projects: [],
            skipped: [], errors: errors, lastFSEventID: 1)
    }

    /// Adds one record and flushes once the coalesce window has passed.
    private func single(_ record: RunRecord, projectName: String? = nil) -> NotificationText? {
        var composer = NotificationComposer()
        composer.add(record, projectName: projectName)
        return composer.flush(now: record.finishedAt.addingTimeInterval(300))
    }

    @Test func composerSingleAfterInstall() {
        let text = single(record(.dedupe, .afterInstall, bytes: 340_000_000), projectName: "linkbreeze")

        #expect(text == NotificationText(title: "Featherweight", body: "Freed 340 MB after install in linkbreeze"))
    }

    @Test func composerWeekly() {
        let text = single(record(.clean, .scheduled, bytes: 4_200_000_000))

        #expect(text == NotificationText(title: "Featherweight", body: "Weekly cleanup freed 4.2 GB"))
    }

    @Test func composerDailyCleanupAndSweep() {
        var composer = NotificationComposer()
        composer.add(record(.clean, .scheduled, bytes: 4_200_000_000), projectName: nil, frequency: .daily)
        #expect(composer.flush(now: t0.addingTimeInterval(300))?.body == "Daily cleanup freed 4.2 GB")

        #expect(single(record(.dedupe, .scheduled, bytes: 340_000_000))?.body == "Daily sweep freed 340 MB")
    }

    @Test func composerCLI() {
        #expect(single(record(.dedupe, .manualCLI, bytes: 340_000_000))
            == NotificationText(title: "Featherweight", body: "Freed 340 MB"))
    }

    @Test func composerSilentWhenNothingFreed() {
        var composer = NotificationComposer()
        composer.add(record(.dedupe, .afterInstall, bytes: 0), projectName: "linkbreeze")

        #expect(composer.nextFlush == nil)
        #expect(composer.flush(now: t0.addingTimeInterval(3600)) == nil)
    }

    @Test func composerIgnoresManualApp() {
        var composer = NotificationComposer()
        composer.add(record(.clean, .manualApp, bytes: 4_200_000_000), projectName: nil)
        composer.add(record(.clean, .manualApp, bytes: 0, errors: ["boom"]), projectName: nil)

        #expect(composer.flush(now: t0.addingTimeInterval(3600)) == nil)
    }

    @Test func composerWaitsForCoalesceWindow() {
        var composer = NotificationComposer()
        composer.add(record(.dedupe, .afterInstall, bytes: 340_000_000), projectName: "linkbreeze")

        #expect(composer.nextFlush == t0.addingTimeInterval(300))
        #expect(composer.flush(now: t0.addingTimeInterval(299)) == nil)
        #expect(composer.flush(now: t0.addingTimeInterval(300)) != nil)
        // Flushed records are gone.
        #expect(composer.nextFlush == nil)
        #expect(composer.flush(now: t0.addingTimeInterval(900)) == nil)
    }

    @Test func composerCoalesces() {
        var composer = NotificationComposer()
        composer.add(record(.dedupe, .afterInstall, bytes: 100_000_000), projectName: "linkbreeze")
        composer.add(record(.dedupe, .scheduled, bytes: 200_000_000, at: 100), projectName: nil)
        composer.add(record(.clean, .manualCLI, bytes: 40_000_000, at: 250), projectName: nil)

        #expect(composer.flush(now: t0.addingTimeInterval(299)) == nil)
        #expect(composer.flush(now: t0.addingTimeInterval(300))
            == NotificationText(title: "Featherweight", body: "Freed 340 MB across 3 runs"))
    }

    @Test func composerErrorTitle() {
        var composer = NotificationComposer()
        composer.add(record(.dedupe, .scheduled, bytes: 340_000_000), projectName: nil)
        composer.add(record(.clean, .scheduled, bytes: 0, errors: ["hash cache: disk full", "second"], at: 10),
                     projectName: nil)

        #expect(composer.flush(now: t0.addingTimeInterval(300))
            == NotificationText(title: "Featherweight hit a problem", body: "hash cache: disk full"))
    }
}
