import Foundation
import Testing
@testable import FeatherweightCore

struct ConversionBackupTests {
    private func makePaths(_ tree: TempTree) -> AppPaths {
        AppPaths(base: tree.url("state"), launchAgentsDir: tree.url("LaunchAgents"), home: tree.root)
    }

    @Test func backupRestoresByteForByte() throws {
        let state = try TempTree()
        defer { state.remove() }
        let original = "{\n    \"name\": \"café\",\r\n  \"scripts\": {}\n}\n\n"
        let project = try TempTree(["package.json": original, "notes.md": "mine"])
        defer { project.remove() }
        let paths = makePaths(state)

        let backup = try ConversionBackup.create(
            root: project.root, relativePaths: ["package.json", "pnpm-lock.yaml"], manager: .npm, paths: paths)
        #expect(backup.entries == ["package.json": true, "pnpm-lock.yaml": false])
        #expect(backup.originalManager == .npm)

        try project.add(["package.json": "{}", "pnpm-lock.yaml": "lockfileVersion: '9.0'\n", "notes.md": "edited"])
        try backup.restore(paths: paths)

        #expect(try Data(contentsOf: project.url("package.json")) == Data(original.utf8))
        #expect(!FileManager.default.fileExists(atPath: project.url("pnpm-lock.yaml").path))
        #expect(try String(contentsOf: project.url("notes.md"), encoding: .utf8) == "edited")
    }

    @Test func backupRestoresAFileThatWasDeleted() throws {
        let state = try TempTree()
        defer { state.remove() }
        let project = try TempTree(["package-lock.json": "{\"lockfileVersion\": 3}\n"])
        defer { project.remove() }
        let paths = makePaths(state)

        let backup = try ConversionBackup.create(
            root: project.root, relativePaths: ["package-lock.json"], manager: .npm, paths: paths)
        try FileManager.default.removeItem(at: project.url("package-lock.json"))
        try backup.restore(paths: paths)

        #expect(try Data(contentsOf: project.url("package-lock.json")) == Data("{\"lockfileVersion\": 3}\n".utf8))
    }

    @Test func backupRoundTripsSpacesTrailingSpacesAndUnicode() throws {
        let state = try TempTree()
        defer { state.remove() }
        let outer = try TempTree()
        defer { outer.remove() }
        // Review Focus 4: the project folder itself has a trailing space and unicode.
        let projectRoot = URL(fileURLWithPath: outer.root.path + "/Lightroom ", isDirectory: true)
        let files = ["package.json": "{\"name\":\"ü\"}", ".github/work flows/ci café.yml": "run: npm ci\n",
                     "Docker file ": "FROM node\n"]
        for (rel, text) in files {
            let url = URL(fileURLWithPath: projectRoot.path + "/" + rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let paths = makePaths(state)

        let backup = try ConversionBackup.create(
            root: projectRoot, relativePaths: Array(files.keys) + ["MAgPIE Studio.txt"], manager: .yarn, paths: paths)
        for rel in files.keys {
            try Data("changed".utf8).write(to: URL(fileURLWithPath: projectRoot.path + "/" + rel))
        }
        try Data("new".utf8).write(to: URL(fileURLWithPath: projectRoot.path + "/MAgPIE Studio.txt"))
        try backup.restore(paths: paths)

        for (rel, text) in files {
            #expect(try Data(contentsOf: URL(fileURLWithPath: projectRoot.path + "/" + rel)) == Data(text.utf8))
        }
        #expect(!FileManager.default.fileExists(atPath: projectRoot.path + "/MAgPIE Studio.txt"))
        #expect(ConversionBackup.latest(for: projectRoot, paths: paths)?.id == backup.id)
    }

    @Test func backupKeepsFilePermissions() throws {
        let state = try TempTree()
        defer { state.remove() }
        let project = try TempTree(["run.sh": "#!/bin/sh\n"])
        defer { project.remove() }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: project.url("run.sh").path)
        let paths = makePaths(state)

        let backup = try ConversionBackup.create(root: project.root, relativePaths: ["run.sh"], manager: .npm, paths: paths)
        try FileManager.default.removeItem(at: project.url("run.sh"))
        try backup.restore(paths: paths)

        let mode = try FileManager.default.attributesOfItem(atPath: project.url("run.sh").path)[.posixPermissions] as? Int
        #expect(mode == 0o755)
    }

    @Test func latestPicksNewestBackupForThatProject() throws {
        let state = try TempTree()
        defer { state.remove() }
        let project = try TempTree(["package.json": "{}"])
        defer { project.remove() }
        let other = try TempTree(["package.json": "{}"])
        defer { other.remove() }
        let paths = makePaths(state)

        #expect(ConversionBackup.latest(for: project.root, paths: paths) == nil)
        _ = try ConversionBackup.create(root: project.root, relativePaths: ["package.json"], manager: .npm, paths: paths)
        let newer = try ConversionBackup.create(
            root: project.root, relativePaths: ["package.json"], manager: .yarn, paths: paths)
        _ = try ConversionBackup.create(root: other.root, relativePaths: ["package.json"], manager: .npm, paths: paths)

        let latest = ConversionBackup.latest(for: project.root, paths: paths)
        #expect(latest?.id == newer.id)
        #expect(latest?.originalManager == .yarn)
        #expect(latest?.projectRoot == PhysicalPath.resolve(project.root.path))
    }

    @Test func storedUnderHashedProjectFolderWithManifest() throws {
        let state = try TempTree()
        defer { state.remove() }
        let project = try TempTree(["package.json": "{}"])
        defer { project.remove() }
        let paths = makePaths(state)

        let backup = try ConversionBackup.create(root: project.root, relativePaths: ["package.json"], manager: .npm, paths: paths)
        let folders = try FileManager.default.contentsOfDirectory(atPath: paths.backups.path)
        #expect(folders.count == 1)
        #expect(folders.first?.count == 16)
        let manifest = paths.backups.appendingPathComponent(folders[0])
            .appendingPathComponent(backup.id.uuidString).appendingPathComponent("manifest.json")
        #expect(FileManager.default.fileExists(atPath: manifest.path))
    }
}
