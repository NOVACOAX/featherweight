import Foundation
import Testing

@testable import FeatherweightCore

@Suite struct ProjectRowsTests {
    private let now = Date()

    private func project(
        _ name: String, _ manager: PackageManager = .npm, parent: String? = nil, ageDays: Double = 1
    ) -> ProjectSummary {
        ProjectSummary(
            id: "/dev/" + (parent.map { $0 + "/" } ?? "") + name, name: name,
            parentRoot: parent.map { "/dev/" + $0 }, packageManager: manager, nodeModulesBytes: 1,
            sharedBytes: 0, cacheBytes: 0, lastActive: now.addingTimeInterval(-ageDays * 86_400),
            status: "Up to date", gitBranch: nil, upstream: nil, remoteURL: nil)
    }

    private func titles(_ rows: [ProjectRow]) -> [String] { rows.map(\.title) }

    @Test func aChildFollowsItsVisibleParentIndented() {
        let projects = [
            project("functions", parent: "alpha", ageDays: 1), project("beta", ageDays: 5),
            project("alpha", ageDays: 3),
        ]
        let rows = ProjectRows.arrange(projects, filter: .all, search: "")
        // alpha (3 days) before beta (5 days), even though its child is the most recent.
        #expect(titles(rows) == ["alpha", "functions", "beta"])
        #expect(rows.map(\.depth) == [0, 1, 0])
    }

    @Test func grandchildrenNestDeeper() {
        let projects = [
            project("alpha"),
            ProjectSummary(
                id: "/dev/alpha/functions", name: "functions", parentRoot: "/dev/alpha", packageManager: .npm,
                nodeModulesBytes: 1, sharedBytes: 0, cacheBytes: 0, lastActive: nil, status: "Up to date",
                gitBranch: nil, upstream: nil, remoteURL: nil),
            ProjectSummary(
                id: "/dev/alpha/functions/inner", name: "inner", parentRoot: "/dev/alpha/functions",
                packageManager: .npm, nodeModulesBytes: 1, sharedBytes: 0, cacheBytes: 0, lastActive: nil,
                status: "Up to date", gitBranch: nil, upstream: nil, remoteURL: nil),
        ]
        #expect(ProjectRows.arrange(projects, filter: .all, search: "").map(\.depth) == [0, 1, 2])
    }

    @Test func aChildWhoseParentIsFilteredOutStandsAloneWithItsParentsName() {
        let projects = [project("alpha", .pnpm), project("functions", .npm, parent: "alpha")]
        let rows = ProjectRows.arrange(projects, filter: .npm, search: "")
        #expect(titles(rows) == ["alpha/functions"])
        #expect(rows.map(\.depth) == [0])
    }

    @Test func filterByManagerKeepsOnlyThatManager() {
        let projects = [project("a", .npm), project("b", .pnpm), project("c", .yarn), project("d", .bun), project("e", .none)]
        #expect(titles(ProjectRows.arrange(projects, filter: .all, search: "")).count == 5)
        #expect(titles(ProjectRows.arrange(projects, filter: .pnpm, search: "")) == ["b"])
        #expect(titles(ProjectRows.arrange(projects, filter: .yarn, search: "")) == ["c"])
        #expect(titles(ProjectRows.arrange(projects, filter: .bun, search: "")) == ["d"])
    }

    @Test func searchMatchesNamesIgnoringCaseAndSurroundingSpace() {
        let projects = [project("MAgPIE Studio"), project("magpie_executive_web"), project("linkbreeze")]
        #expect(Set(titles(ProjectRows.arrange(projects, filter: .all, search: " magpie "))) == ["MAgPIE Studio", "magpie_executive_web"])
        #expect(ProjectRows.arrange(projects, filter: .all, search: "zzz").isEmpty)
    }

    @Test func searchAndFilterCombine() {
        let projects = [project("magpie-a", .npm), project("magpie-b", .pnpm), project("other", .pnpm)]
        #expect(titles(ProjectRows.arrange(projects, filter: .pnpm, search: "magpie")) == ["magpie-b"])
    }

    @Test func noProjectAppearsTwice() {
        let projects = [
            project("alpha"), project("functions", parent: "alpha"), project("beta"),
            project("functions", parent: "beta"),
        ]
        let rows = ProjectRows.arrange(projects, filter: .all, search: "")
        #expect(rows.count == 4)
        #expect(Set(rows.map(\.id)).count == 4)
    }
}
