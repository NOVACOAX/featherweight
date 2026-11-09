import Foundation
import Testing

@testable import FeatherweightCore

@Suite struct ProjectSummaryTests {
    private func candidate(_ relativePath: String, skip: SkipReason?) -> CacheCandidate {
        CacheCandidate(
            projectRoot: "/p", folder: "/p/" + relativePath, relativePath: relativePath,
            allocatedBytes: 10, skip: skip)
    }

    private func status(
        _ pm: PackageManager = .npm, _ candidates: [CacheCandidate] = [],
        cleared: Bool = false, bytes: Int64? = nil
    ) -> String {
        ProjectSummary.status(
            packageManager: pm, candidates: candidates, clearedByLastClean: cleared,
            clearedBytes: bytes)
    }

    @Test func statusMapping() {
        #expect(status() == "Up to date")
        #expect(status(.pnpm, [candidate(".next", skip: .trackedInGit)], cleared: true) == "Linked by pnpm")
        #expect(status(.npm, [candidate(".next", skip: .recentlyActive)]) == "Skipped: active")
        #expect(status(.npm, [candidate(".next", skip: .trackedInGit)]) == "Tracked in git")
        #expect(status(.npm, [candidate(".output", skip: .notEnabled)]) == ".output kept")
        #expect(status(.npm, [candidate(".vinxi", skip: .notEnabled)]) == ".vinxi kept")
        #expect(status(.npm, [candidate(".next", skip: .gitUnavailable)]) == "Git unavailable")
        #expect(status(.npm, [candidate(".next", skip: .pathChanged)]) == "Skipped")
        #expect(status(.npm, [candidate(".next", skip: .containsRepository)]) == "Skipped")
        #expect(status(.npm, [candidate(".next", skip: nil)]) == "Up to date")
    }

    @Test func clearedStatusUsesBytesWhenKnown() {
        #expect(status(.npm, [], cleared: true, bytes: 1_000_000) == "Cleared " + ByteFormat.string(1_000_000))
        #expect(status(.npm, [], cleared: true) == "Cleared caches")
    }

    @Test func blockingSkipsOutrankClearedAndKeptNotices() {
        let kept = candidate(".output", skip: .notEnabled)
        #expect(status(.npm, [kept], cleared: true, bytes: 5) == "Cleared " + ByteFormat.string(5))
        #expect(
            status(.npm, [kept, candidate(".next", skip: .recentlyActive)], cleared: true, bytes: 5)
                == "Skipped: active")
        #expect(
            status(.npm, [kept, candidate(".next", skip: .trackedInGit)]) == "Tracked in git")
    }
}
