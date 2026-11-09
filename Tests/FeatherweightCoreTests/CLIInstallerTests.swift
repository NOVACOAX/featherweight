import Foundation
import Testing

@testable import FeatherweightCore

@Suite struct CLIInstallerTests {
    /// A fake home with a stand-in `featherweight` executable, and candidate folders that all live
    /// inside it, so nothing here ever looks at the real `/opt/homebrew/bin` or `/usr/local/bin`.
    private struct Fixture {
        let tree: TempTree
        let cli: URL

        init(_ files: [String: String] = [:]) throws {
            tree = try TempTree(files.merging(["App/featherweight": "#!/bin/sh\n"]) { $1 })
            cli = tree.url("App/featherweight")
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        }

        var localBin: URL { tree.url(".local/bin") }
        var brewBin: URL { tree.url("brew/bin") }
        var usrLocalBin: URL { tree.url("usr-local/bin") }

        func installer(path: String) -> CLIInstaller {
            CLIInstaller(
                home: tree.root, pathEnv: path,
                candidates: [localBin, brewBin, usrLocalBin])
        }
    }

    @Test func cliTargetPrefersLocalBin() throws {
        let fixture = try Fixture([".local/bin/": "", "brew/bin/": ""])
        defer { fixture.tree.remove() }
        let path = "\(fixture.localBin.path):\(fixture.brewBin.path):/usr/bin"

        #expect(fixture.installer(path: path).targetDirectory() == fixture.localBin)
    }

    @Test func defaultCandidatesStartWithLocalBin() throws {
        let tree = try TempTree([".local/bin/": ""])
        defer { tree.remove() }

        #expect(CLIInstaller(home: tree.root, pathEnv: "\(tree.url(".local/bin").path):/usr/bin")
            .targetDirectory() == tree.url(".local/bin"))
    }

    @Test func cliTargetSkipsDirectoriesNotOnPathOrNotWritable() throws {
        let fixture = try Fixture([".local/bin/": "", "brew/bin/": "", "usr-local/bin/": ""])
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.brewBin.path)
            fixture.tree.remove()
        }
        // ~/.local/bin exists but is not on PATH; brew/bin is on PATH but read-only.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.brewBin.path)
        let path = "\(fixture.brewBin.path):\(fixture.usrLocalBin.path)/:/usr/bin"

        #expect(fixture.installer(path: path).targetDirectory() == fixture.usrLocalBin)
    }

    @Test func cliNoWritableDirThrowsWithSuggestion() throws {
        let fixture = try Fixture()
        defer { fixture.tree.remove() }
        // ~/.local/bin is on PATH but missing; nothing else is on PATH.
        let installer = fixture.installer(path: "\(fixture.localBin.path):/usr/bin")

        #expect(installer.targetDirectory() == nil)
        #expect(throws: CLIInstallError.noWritableDirectoryOnPath(
            suggestedLine: "export PATH=\"$HOME/.local/bin:$PATH\"")) {
            try installer.install(cli: fixture.cli)
        }
    }

    @Test func cliInstallCreatesSymlink() throws {
        let fixture = try Fixture([".local/bin/": ""])
        defer { fixture.tree.remove() }
        let installer = fixture.installer(path: "\(fixture.localBin.path):/usr/bin")

        let link = try installer.install(cli: fixture.cli)

        #expect(link == fixture.localBin.appendingPathComponent("featherweight"))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == fixture.cli.path)
        #expect(installer.installedLinks() == [link])

        try installer.uninstall()

        #expect(!FileManager.default.fileExists(atPath: link.path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil)
        #expect(installer.installedLinks().isEmpty)
        // The real executable is untouched.
        #expect(FileManager.default.fileExists(atPath: fixture.cli.path))
    }

    @Test func installingAgainPointsTheLinkAtTheNewExecutable() throws {
        let fixture = try Fixture([".local/bin/": "", "Moved/featherweight": "#!/bin/sh\n"])
        defer { fixture.tree.remove() }
        let moved = fixture.tree.url("Moved/featherweight")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: moved.path)
        let installer = fixture.installer(path: fixture.localBin.path)

        _ = try installer.install(cli: fixture.cli)
        let link = try installer.install(cli: moved)

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == moved.path)
    }

    @Test func installRefusesToReplaceARegularFile() throws {
        let fixture = try Fixture([".local/bin/featherweight": "someone else's tool"])
        defer { fixture.tree.remove() }
        let installer = fixture.installer(path: fixture.localBin.path)

        #expect(throws: CLIInstallError.fileInTheWay(fixture.localBin.appendingPathComponent("featherweight"))) {
            try installer.install(cli: fixture.cli)
        }
        #expect(try String(contentsOf: fixture.localBin.appendingPathComponent("featherweight"), encoding: .utf8)
            == "someone else's tool")
    }

    @Test func installRefusesToReplaceSomeoneElsesSymlink() throws {
        let fixture = try Fixture([".local/bin/": "", "Other/tool": "x"])
        defer { fixture.tree.remove() }
        let link = fixture.localBin.appendingPathComponent("featherweight")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.tree.url("Other/tool"))

        #expect(throws: CLIInstallError.fileInTheWay(link)) {
            try fixture.installer(path: fixture.localBin.path).install(cli: fixture.cli)
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == fixture.tree.url("Other/tool").path)
    }

    @Test func installRefusesAMissingExecutable() throws {
        let fixture = try Fixture([".local/bin/": ""])
        defer { fixture.tree.remove() }
        let missing = fixture.tree.url("App/nope")

        #expect(throws: CLIInstallError.executableNotFound(missing)) {
            try fixture.installer(path: fixture.localBin.path).install(cli: missing)
        }
        #expect(fixture.installer(path: fixture.localBin.path).installedLinks().isEmpty)
    }

    @Test func uninstallOnlyRemovesLinksToAFeatherweightExecutable() throws {
        let fixture = try Fixture([".local/bin/": "", "brew/bin/": "", "Other/tool": "x"])
        defer { fixture.tree.remove() }
        // Someone else's `featherweight` symlink in one folder, ours in another.
        try FileManager.default.createSymbolicLink(
            at: fixture.brewBin.appendingPathComponent("featherweight"),
            withDestinationURL: fixture.tree.url("Other/tool"))
        let installer = fixture.installer(path: fixture.localBin.path)
        let ours = try installer.install(cli: fixture.cli)

        try installer.uninstall()

        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: ours.path)) == nil)
        #expect((try? FileManager.default.destinationOfSymbolicLink(
            atPath: fixture.brewBin.appendingPathComponent("featherweight").path)) != nil)
    }

    @Test func uninstallWithNothingInstalledIsFine() throws {
        let fixture = try Fixture()
        defer { fixture.tree.remove() }

        try fixture.installer(path: "/usr/bin").uninstall()
    }

    @Test func uninstallRemovesALinkWhoseTargetWasDeleted() throws {
        let fixture = try Fixture([".local/bin/": ""])
        defer { fixture.tree.remove() }
        let installer = fixture.installer(path: fixture.localBin.path)
        let link = try installer.install(cli: fixture.cli)
        try FileManager.default.removeItem(at: fixture.cli)   // the app was deleted

        #expect(installer.installedLinks() == [link])
        try installer.uninstall()
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil)
    }
}
