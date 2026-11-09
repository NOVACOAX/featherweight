import Foundation
import Testing
@testable import FeatherweightCore

struct ConversionEligibilityTests {
    private let longAgo = Date(timeIntervalSinceNow: -30 * 24 * 3600)

    private func project(_ tree: TempTree, _ manager: PackageManager) -> Project {
        Project(root: tree.root, parentRoot: nil, packageManager: manager, nodeModules: nil)
    }

    private func check(_ tree: TempTree, _ manager: PackageManager) throws -> Ineligibility? {
        ConversionEligibility.check(project(tree, manager), activity: ActivityChecker(), windowHours: 24)
    }

    @Test func eligibleNpmProjectWithOldMtimes() throws {
        let tree = try TempTree(["package.json": #"{"name":"a"}"#, "package-lock.json": "{}"])
        defer { tree.remove() }
        try tree.setAllMTimes(to: longAgo)
        #expect(try check(tree, .npm) == nil)
    }

    @Test func eligibleYarnProjectWithOldMtimes() throws {
        let tree = try TempTree(["package.json": #"{"name":"a"}"#, "yarn.lock": ""])
        defer { tree.remove() }
        try tree.setAllMTimes(to: longAgo)
        #expect(try check(tree, .yarn) == nil)
    }

    @Test func bunIsIneligible() throws {
        let tree = try TempTree(["package.json": "{}", "bun.lock": ""])
        defer { tree.remove() }
        try tree.setAllMTimes(to: longAgo)
        #expect(try check(tree, .bun) == .bun)
    }

    @Test func pnpmIsAlreadyPnpm() throws {
        let tree = try TempTree(["package.json": "{}", "pnpm-lock.yaml": ""])
        defer { tree.remove() }
        try tree.setAllMTimes(to: longAgo)
        #expect(try check(tree, .pnpm) == .alreadyPnpm)
    }

    @Test func workspacesAreIneligible() throws {
        let tree = try TempTree([
            "package.json": #"{"name":"mono","workspaces":["packages/*"]}"#, "package-lock.json": "{}",
        ])
        defer { tree.remove() }
        try tree.setAllMTimes(to: longAgo)
        #expect(try check(tree, .npm) == .workspaces)
    }

    @Test func yarnWorkspacesObjectFormIsIneligible() throws {
        let tree = try TempTree([
            "package.json": #"{"workspaces":{"packages":["apps/*"]}}"#, "yarn.lock": "",
        ])
        defer { tree.remove() }
        try tree.setAllMTimes(to: longAgo)
        #expect(try check(tree, .yarn) == .workspaces)
    }

    @Test func recentlyActiveIsIneligible() throws {
        let tree = try TempTree(["package.json": "{}", "package-lock.json": "{}"])
        defer { tree.remove() }
        #expect(try check(tree, .npm) == .recentlyActive)
    }

    @Test func noLockfileIsIneligible() throws {
        let tree = try TempTree(["package.json": "{}"])
        defer { tree.remove() }
        try tree.setAllMTimes(to: longAgo)
        #expect(try check(tree, .none) == .noLockfile)
    }

    @Test func messages() {
        #expect(Ineligibility.bun.message(windowHours: 24) == "pnpm can't import bun lockfiles")
        #expect(Ineligibility.alreadyPnpm.message(windowHours: 24) == "Already uses pnpm")
        #expect(Ineligibility.workspaces.message(windowHours: 24) == "Monorepos with workspaces aren't supported yet")
        #expect(Ineligibility.recentlyActive.message(windowHours: 24) == "Active in the last 24 hours")
        #expect(Ineligibility.recentlyActive.message(windowHours: 1) == "Active in the last hour")
        #expect(Ineligibility.noLockfile.message(windowHours: 24) == "No lockfile to import")
    }
}
