import Foundation
import Testing
@testable import FeatherweightCore

@Suite struct ProjectScannerTests {
    static let excluded: Set<String> = [".next", ".nuxt", ".vite", ".turbo", ".parcel-cache", ".cache", ".output"]
    let scanner = ProjectScanner(excludedDirectoryNames: ProjectScannerTests.excluded)

    @Test func findsTopLevelAndNestedProjects() throws {
        let tree = try TempTree([
            "a/package.json": "{}",
            "a/functions/package.json": "{}",
            "b/dashboard/package.json": "{}",
        ])
        defer { tree.remove() }
        let projects = scanner.scan(folders: [tree.root])
        #expect(projects.count == 3)
        #expect(projects.map(\.root.path) == projects.map(\.root.path).sorted())
        let a = try #require(projects.first { $0.root.lastPathComponent == "a" })
        let functions = try #require(projects.first { $0.root.lastPathComponent == "functions" })
        #expect(a.parentRoot == nil)
        #expect(functions.parentRoot?.path == a.root.path)
        let dashboard = try #require(projects.first { $0.root.lastPathComponent == "dashboard" })
        #expect(dashboard.parentRoot == nil)
    }

    @Test func skipsNodeModulesCachesAndVenvs() throws {
        let tree = try TempTree([
            "a/package.json": "{}",
            "a/node_modules/x/package.json": "{}",
            "a/.next/package.json": "{}",
            "a/.git/package.json": "{}",
            "py/.venv/lib/gradio/package.json": "{}",
            "py/venv/lib/foo/package.json": "{}",
            "py/custom/pyvenv.cfg": "home = /usr",
            "py/custom/lib/package.json": "{}",
            "py/custom/package.json": "{}",
        ])
        defer { tree.remove() }
        let projects = scanner.scan(folders: [tree.root])
        #expect(projects.map(\.root.lastPathComponent) == ["a"])
    }

    @Test func doesNotFollowSymlinkedDirectories() throws {
        let tree = try TempTree([
            "real/package.json": "{}",
            "scan/placeholder.txt": "",
        ])
        defer { tree.remove() }
        try FileManager.default.createSymbolicLink(
            atPath: tree.url("scan/link").path, withDestinationPath: tree.url("real").path)
        #expect(scanner.scan(folders: [tree.url("scan")]).isEmpty)
    }

    @Test func recordsNodeModulesAndPackageManager() throws {
        let tree = try TempTree([
            "a/package.json": "{}",
            "a/pnpm-lock.yaml": "",
            "a/node_modules/x/index.js": "",
            "b/package.json": "{}",
        ])
        defer { tree.remove() }
        let projects = scanner.scan(folders: [tree.root])
        let a = try #require(projects.first { $0.root.lastPathComponent == "a" })
        let b = try #require(projects.first { $0.root.lastPathComponent == "b" })
        #expect(a.packageManager == .pnpm)
        #expect(a.nodeModules?.lastPathComponent == "node_modules")
        #expect(b.packageManager == .none)
        #expect(b.nodeModules == nil)
    }

    @Test(arguments: [
        ("package-lock.json", PackageManager.npm),
        ("npm-shrinkwrap.json", .npm),
        ("pnpm-lock.yaml", .pnpm),
        ("yarn.lock", .yarn),
        ("bun.lock", .bun),
        ("bun.lockb", .bun),
    ])
    func detectsEachPackageManager(lockfile: String, expected: PackageManager) throws {
        let tree = try TempTree(["p/package.json": "{}", "p/\(lockfile)": ""])
        defer { tree.remove() }
        #expect(PackageManagerDetector.detect(root: tree.url("p")) == expected)
    }

    @Test func detectsNoneWithoutLockfile() throws {
        let tree = try TempTree(["p/package.json": "{}"])
        defer { tree.remove() }
        #expect(PackageManagerDetector.detect(root: tree.url("p")) == PackageManager.none)
    }

    @Test func handlesSpacesAndTrailingSpace() throws {
        let tree = try TempTree([
            "MAgPIE Studio/package.json": "{}",
            "Lightroom /package.json": "{}",
        ])
        defer { tree.remove() }
        let projects = scanner.scan(folders: [tree.root])
        #expect(projects.count == 2)
        #expect(projects.contains { $0.root.path.hasSuffix("/MAgPIE Studio") })
        #expect(projects.contains { $0.root.path.hasSuffix("/Lightroom ") })
    }

    @Test func scansSymlinkedScanFolder() throws {
        let tree = try TempTree(["real/proj/package.json": "{}", "links/placeholder": ""])
        defer { tree.remove() }
        try FileManager.default.createSymbolicLink(
            atPath: tree.url("links/dev").path, withDestinationPath: tree.url("real").path)
        let projects = scanner.scan(folders: [tree.url("links/dev")])
        #expect(projects.count == 1)
        #expect(projects.first?.root.path == tree.url("real/proj").path)
    }

    @Test func rootURLsAreCanonicalAcrossDiscoveryPaths() throws {
        let tree = try TempTree([
            "a/package.json": "{}",
            "a/node_modules/x/index.js": "",
            "a/functions/package.json": "{}",
        ])
        defer { tree.remove() }
        // Found via enumeration of the parent folder.
        let viaParent = try #require(scanner.scan(folders: [tree.root]).first { $0.root.lastPathComponent == "a" })
        // Found as the scanned folder itself (passed without trailing slash and with it).
        let viaSelf = try #require(scanner.scan(folders: [tree.url("a")]).first { $0.root.lastPathComponent == "a" })
        let viaSelfSlash = try #require(
            scanner.scan(folders: [URL(fileURLWithPath: tree.url("a").path + "/", isDirectory: true)])
                .first { $0.root.lastPathComponent == "a" })
        #expect(viaParent == viaSelf)
        #expect(viaParent == viaSelfSlash)
        #expect(viaParent.root.path == viaSelf.root.path)
        #expect(viaParent.root.absoluteString == viaSelf.root.absoluteString)
        #expect(viaParent.nodeModules == viaSelf.nodeModules)
        // parentRoot of a nested project equals the parent project's root exactly.
        let nested = try #require(scanner.scan(folders: [tree.root]).first { $0.root.lastPathComponent == "functions" })
        #expect(nested.parentRoot == viaParent.root)
    }
}
