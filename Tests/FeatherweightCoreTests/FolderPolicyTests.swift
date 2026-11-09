import Foundation
import Testing

@testable import FeatherweightCore

@Suite struct FolderPolicyTests {
    @Test func iCloudPathsRejected() throws {
        let tree = try TempTree([
            "Library/Mobile Documents/com~apple~CloudDocs/x/": "",
            "Library/CloudStorage/GoogleDrive-a/x/": "",
        ])
        defer { tree.remove() }
        let policy = FolderPolicy(home: tree.root)

        #expect(policy.evaluate(tree.url("Library/Mobile Documents/com~apple~CloudDocs/x")) == .rejectedSync)
        #expect(policy.evaluate(tree.url("Library/CloudStorage/GoogleDrive-a/x")) == .rejectedSync)
    }

    @Test func syncFoldersAreRejectedEvenWhenTheyDoNotExistYet() throws {
        let tree = try TempTree()
        defer { tree.remove() }

        #expect(FolderPolicy(home: tree.root)
            .evaluate(tree.url("Library/Mobile Documents/com~apple~CloudDocs/new")) == .rejectedSync)
    }

    @Test func syncFoldersReachedThroughASymlinkAreRejected() throws {
        let tree = try TempTree(["Library/CloudStorage/Dropbox/work/": "", "Developer/": ""])
        defer { tree.remove() }
        try FileManager.default.createSymbolicLink(
            at: tree.url("Developer/link"), withDestinationURL: tree.url("Library/CloudStorage/Dropbox/work"))

        #expect(FolderPolicy(home: tree.root).evaluate(tree.url("Developer/link")) == .rejectedSync)
    }

    @Test func ordinaryFolderOK() throws {
        let tree = try TempTree(["Developer/app/": "", "Library/Application Support/x/": ""])
        defer { tree.remove() }
        let policy = FolderPolicy(home: tree.root)

        #expect(policy.evaluate(tree.url("Developer")) == .ok)
        #expect(policy.evaluate(tree.url("Library/Application Support/x")) == .ok)
    }

    @Test func unreadableFolderUnderDocumentsNeedsAccess() throws {
        let tree = try TempTree(["Documents/work/": "", "Desktop/work/": "", "Downloads/work/": "", "Developer/locked/": ""])
        defer {
            for name in ["Documents/work", "Desktop/work", "Downloads/work", "Developer/locked"] {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tree.url(name).path)
            }
            tree.remove()
        }
        for name in ["Documents/work", "Desktop/work", "Downloads/work", "Developer/locked"] {
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: tree.url(name).path)
        }
        let policy = FolderPolicy(home: tree.root)

        #expect(policy.evaluate(tree.url("Documents/work")) == .needsAccess)
        #expect(policy.evaluate(tree.url("Desktop/work")) == .needsAccess)
        #expect(policy.evaluate(tree.url("Downloads/work")) == .needsAccess)
        // Outside the protected folders an unreadable folder is not a privacy-prompt problem.
        #expect(policy.evaluate(tree.url("Developer/locked")) == .ok)
    }

    @Test func readableFolderUnderDocumentsIsOK() throws {
        let tree = try TempTree(["Documents/work/a.txt": "x"])
        defer { tree.remove() }

        #expect(FolderPolicy(home: tree.root).evaluate(tree.url("Documents/work")) == .ok)
    }

    @Test func namesThatOnlyLookLikeSyncFoldersAreOK() throws {
        let tree = try TempTree(["Library/Mobile Documents Backup/x/": "", "Developer/Library/CloudStorage/": ""])
        defer { tree.remove() }
        let policy = FolderPolicy(home: tree.root)

        #expect(policy.evaluate(tree.url("Library/Mobile Documents Backup/x")) == .ok)
        #expect(policy.evaluate(tree.url("Developer/Library/CloudStorage")) == .ok)
    }
}

@Suite struct FolderPolicyVetTests {
    @Test func theDefaultProjectsFolderIsCheckedLikeAnyOther() throws {
        // ~/Developer is a link into a synced folder: the default settings pick it, the policy refuses it.
        let tree = try TempTree(["Library/CloudStorage/Dropbox/dev/": ""])
        defer { tree.remove() }
        try FileManager.default.createSymbolicLink(
            at: tree.url("Developer"), withDestinationURL: tree.url("Library/CloudStorage/Dropbox/dev"))
        let defaults = Settings.defaults(home: tree.root)
        #expect(defaults.projectFolders == [tree.url("Developer").path])

        let result = FolderPolicy(home: tree.root).vet(defaults.projectFolders)

        #expect(result.usable.isEmpty)
        #expect(result.refused.map(\.verdict) == [.rejectedSync])
        #expect(result.refused.map(\.path) == [tree.url("Developer").path])
    }

    @Test func ordinaryFoldersPassAndOrderIsKept() throws {
        let tree = try TempTree(["Developer/": "", "Work/": "", "Library/Mobile Documents/x/": ""])
        defer { tree.remove() }
        let paths = [tree.url("Developer").path, tree.url("Library/Mobile Documents/x").path, tree.url("Work").path]

        let result = FolderPolicy(home: tree.root).vet(paths)

        #expect(result.usable == [paths[0], paths[2]])
        #expect(result.refused.map(\.path) == [paths[1]])
    }

    @Test func noFoldersMeansNothingToVet() {
        let result = FolderPolicy(home: URL(fileURLWithPath: "/nonexistent-home")).vet([])
        #expect(result.usable.isEmpty && result.refused.isEmpty)
    }
}

@Suite struct CustomCacheFolderTests {
    private let existing = [CacheFolderSetting(relativePath: ".next", enabled: true, isBuiltIn: true)]

    @Test func acceptsASafeName() throws {
        let setting = try CacheFolderSetting.custom(named: "  .astro \n", existing: existing)

        #expect(setting == CacheFolderSetting(relativePath: ".astro", enabled: true, isBuiltIn: false))
    }

    @Test func acceptsANestedPathAndDropsATrailingSlash() throws {
        let setting = try CacheFolderSetting.custom(named: "node_modules/.parcel-cache/", existing: existing)

        #expect(setting.relativePath == "node_modules/.parcel-cache")
    }

    @Test(arguments: ["", "   ", "/etc", "../x", "a/../b", "./x", ".git", "a/.GIT/b", "node_modules", "a//b"])
    func rejectsUnsafeNames(_ name: String) {
        #expect(throws: CustomCacheFolderError.invalid) {
            try CacheFolderSetting.custom(named: name, existing: existing)
        }
    }

    @Test func rejectsADuplicateIgnoringCase() {
        #expect(throws: CustomCacheFolderError.duplicate(".NEXT")) {
            try CacheFolderSetting.custom(named: ".NEXT", existing: existing)
        }
    }

    @Test func errorsExplainThemselves() {
        #expect(CustomCacheFolderError.invalid.errorDescription?.contains("inside the project") == true)
        #expect(CustomCacheFolderError.duplicate(".next").errorDescription?.contains(".next") == true)
    }
}
