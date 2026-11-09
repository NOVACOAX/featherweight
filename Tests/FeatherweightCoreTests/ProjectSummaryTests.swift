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

    @Test func skipReasonText() {
        #expect(SkipReason.recentlyActive.displayText(activityWindowHours: 24) == "Active in the last 24 hours")
        #expect(SkipReason.recentlyActive.displayText(activityWindowHours: 1) == "Active in the last hour")
        #expect(SkipReason.trackedInGit.displayText(activityWindowHours: 24) == "Tracked in git")
        #expect(SkipReason.notEnabled.displayText(activityWindowHours: 24) == "Turned off in Settings")
        #expect(SkipReason.gitUnavailable.displayText(activityWindowHours: 24) == "Git unavailable")
        #expect(SkipReason.pathChanged.displayText(activityWindowHours: 24) == "Changed during cleanup")
        #expect(SkipReason.containsRepository.displayText(activityWindowHours: 24) == "Contains a git repository")
    }
}

@Suite struct ProjectSummarySkipReasonTests {
    private func candidate(_ skip: SkipReason?) -> CacheCandidate {
        CacheCandidate(projectRoot: "/p", folder: "/p/.next", relativePath: ".next", allocatedBytes: 1, skip: skip)
    }

    @Test func blockingSkipFollowsTheStatusPrecedenceAndIgnoresTurnedOffFolders() {
        #expect(ProjectSummary.blockingSkip([]) == nil)
        #expect(ProjectSummary.blockingSkip([candidate(nil), candidate(.notEnabled)]) == nil)
        #expect(ProjectSummary.blockingSkip([candidate(.trackedInGit), candidate(.recentlyActive)]) == .recentlyActive)
        #expect(ProjectSummary.blockingSkip([candidate(.gitUnavailable), candidate(.trackedInGit)]) == .trackedInGit)
        #expect(ProjectSummary.blockingSkip([candidate(.containsRepository)]) == .containsRepository)
    }

    @Test func olderProjectsFilesWithoutASkipReasonStillLoad() throws {
        let json = """
        [{"id":"/p","name":"p","packageManager":"npm","nodeModulesBytes":1,"sharedBytes":0,
          "cacheBytes":0,"status":"Skipped: active"}]
        """
        let loaded = try JSONDecoder().decode([ProjectSummary].self, from: Data(json.utf8))
        #expect(loaded.first?.skipReason == nil)
        #expect(loaded.first?.status == "Skipped: active")
    }

    @Test func skipReasonRoundTrips() throws {
        let summary = ProjectSummary(
            id: "/p", name: "p", parentRoot: nil, packageManager: .pnpm, nodeModulesBytes: 1, sharedBytes: 0,
            cacheBytes: 0, lastActive: nil, status: "Linked by pnpm", gitBranch: nil, upstream: nil,
            remoteURL: nil, skipReason: .recentlyActive)
        let decoded = try JSONDecoder().decode(ProjectSummary.self, from: JSONEncoder().encode(summary))
        #expect(decoded.skipReason == .recentlyActive)
    }
}
