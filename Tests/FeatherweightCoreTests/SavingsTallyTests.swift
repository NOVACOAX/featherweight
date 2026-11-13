import Foundation
import Testing
@testable import FeatherweightCore

struct SavingsTallyTests {
    /// `b-c` sorts before `b` once the path continues ("-" is below "/"), so the first member of the
    /// shared group is in `b-c`, not in `b`: the store must credit exactly as one full walk does.
    @Test func combiningStoredTalliesMatchesOneFullWalk() throws {
        let f = try DedupeFixture(["b", "b-c", "c d é "])
        defer { f.tree.remove() }
        _ = f.deduper().run(projects: f.projects, dryRun: false)
        let full = SavingsMeter().measureWithSizes(projects: f.projects, now: Date())
        #expect(full.snapshot.sharedBytes > 0)

        let store = try SavingsTallyStore(url: f.tree.url("state/tallies.sqlite"))
        for project in f.projects {
            try store.replace(root: project.root.path, folder: project.nodeModules!.path, with: SavingsMeter.tally(project))
        }
        let combined = try store.combine(projects: f.projects, included: SavingsMeter.outermost(f.projects), now: Date())

        #expect(combined.snapshot.sharedBytes == full.snapshot.sharedBytes)
        #expect(combined.snapshot.perProject == full.snapshot.perProject)
        #expect(combined.logicalBytes == full.logicalBytes)
        #expect(full.snapshot.perProject[f.root("b-c")] == nil)
        #expect(full.snapshot.perProject[f.root("b")] != nil)
    }

    @Test func retainDropsProjectsThatAreGone() throws {
        let f = try DedupeFixture(["a", "b"])
        defer { f.tree.remove() }
        _ = f.deduper().run(projects: f.projects, dryRun: false)
        let store = try SavingsTallyStore(url: f.tree.url("state/tallies.sqlite"))
        for project in f.projects {
            try store.replace(root: project.root.path, folder: project.nodeModules!.path, with: SavingsMeter.tally(project))
        }

        try store.retain(roots: [f.root("a")])

        #expect(try store.measuredFolders().keys.sorted() == [f.root("a")])
        let onlyA = [f.projects[0]]
        let combined = try store.combine(projects: onlyA, included: [0], now: Date())
        // Alone, a's copy has no partner left to share with.
        #expect(combined.snapshot.sharedBytes == 0)
        #expect(combined.logicalBytes[0] > 0)
    }

    @Test func nestedNodeModulesBelongToTheOuterProject() {
        let outer = Project(root: URL(fileURLWithPath: "/p"), parentRoot: nil, packageManager: .npm,
                            nodeModules: URL(fileURLWithPath: "/p/node_modules"))
        let inner = Project(root: URL(fileURLWithPath: "/p/node_modules/x"), parentRoot: nil, packageManager: .npm,
                            nodeModules: URL(fileURLWithPath: "/p/node_modules/x/node_modules"))
        let sibling = Project(root: URL(fileURLWithPath: "/p2"), parentRoot: nil, packageManager: .npm,
                              nodeModules: URL(fileURLWithPath: "/p2/node_modules"))
        let none = Project(root: URL(fileURLWithPath: "/q"), parentRoot: nil, packageManager: .none, nodeModules: nil)
        #expect(SavingsMeter.outermost([inner, none, outer, sibling]).sorted() == [2, 3])
    }
}
