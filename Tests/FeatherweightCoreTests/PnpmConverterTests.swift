import Foundation
import Testing
@testable import FeatherweightCore

/// Stands in for Task 14's rewriter: replaces one substring per file and attaches fixed warnings.
struct StubRewriter: ConfigRewriting {
    var replacements: [String: (find: String, replace: String)] = [:]
    var warnings: [String: [RewriteWarning]] = [:]

    func rewriteProject(root: URL, from: PackageManager, pnpmVersion: String) throws -> [FileRewrite] {
        try replacements.keys.sorted().map { rel in
            let (find, replace) = replacements[rel]!
            let text = try String(contentsOf: URL(fileURLWithPath: root.path + "/" + rel), encoding: .utf8)
            return FileRewrite(
                relativePath: rel, original: text,
                rewritten: text.replacingOccurrences(of: find, with: replace), warnings: warnings[rel] ?? [])
        }
    }
}

/// Collects progress callbacks from a `@Sendable` closure.
final class StepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ConversionStep] = []
    var steps: [ConversionStep] { lock.lock(); defer { lock.unlock() }; return recorded }
    func record(_ step: ConversionStep) { lock.lock(); recorded.append(step); lock.unlock() }
}

struct PnpmConverterTests {
    static let packageJSON = """
    {
      "name": "app",
      "scripts": { "build": "npm run compile", "compile": "tsc" },
      "dependencies": { "esbuild": "0.21.5", "@prisma/engines": "5.0.0" }
    }

    """
    static let packageLock = """
    {
      "name": "app",
      "lockfileVersion": 3,
      "packages": {
        "": { "name": "app" },
        "node_modules/esbuild": { "version": "0.21.5", "hasInstallScript": true },
        "node_modules/@prisma/engines": { "version": "5.0.0", "hasInstallScript": true }
      }
    }

    """
    static let workflow = "jobs:\n  test:\n    steps:\n      - run: npm ci\n      - run: ./deploy.sh\n"
    static let warning = RewriteWarning(file: ".github/workflows/ci.yml", line: 5, text: "./deploy.sh")

    let state: TempTree
    let tree: TempTree
    let runner = FakeCommandRunner()
    let paths: AppPaths

    init() throws {
        state = try TempTree(["store/esbuild.js": String(repeating: "x", count: 50_000)])
        tree = try TempTree([
            "package.json": Self.packageJSON,
            "package-lock.json": Self.packageLock,
            ".github/workflows/ci.yml": Self.workflow,
            "notes.md": "uncommitted work\n",
            "node_modules/esbuild/package.json": #"{"name":"esbuild"}"#,
            "node_modules/esbuild/main.js": String(repeating: "y", count: 80_000),
        ])
        paths = AppPaths(base: state.url("app"), launchAgentsDir: state.url("LaunchAgents"), home: state.root)
        runner.script("pnpm --version", stdout: "10.33.2\n")
        runner.script("pnpm import") { dir in
            try Data("lockfileVersion: '9.0'\n".utf8).write(to: URL(fileURLWithPath: dir!.path + "/pnpm-lock.yaml"))
        }
        let store = state.url("store/esbuild.js")
        runner.script("pnpm install --frozen-lockfile") { dir in
            // Like pnpm: node_modules holds hard links into the global store.
            let pkg = URL(fileURLWithPath: dir!.path + "/node_modules/.pnpm/esbuild@0.21.5", isDirectory: true)
            try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
            try FileManager.default.linkItem(at: store, to: pkg.appendingPathComponent("main.js"))
        }
    }

    private var project: Project {
        Project(root: tree.root, parentRoot: nil, packageManager: .npm, nodeModules: tree.url("node_modules"))
    }

    private var rewriter: StubRewriter {
        StubRewriter(
            replacements: [
                "package.json": ("npm run compile", "pnpm run compile"),
                ".github/workflows/ci.yml": ("npm ci", "pnpm install --frozen-lockfile"),
            ],
            warnings: [".github/workflows/ci.yml": [Self.warning]])
    }

    private var converter: PnpmConverter { PnpmConverter(runner: runner, paths: paths, rewriter: rewriter) }

    private func bytes(_ rel: String) throws -> Data { try Data(contentsOf: tree.url(rel)) }
    private func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: tree.url(rel).path) }

    private func snapshot() throws -> [String: Data] {
        var files: [String: Data] = [:]
        for rel in ["package.json", "package-lock.json", ".github/workflows/ci.yml", "notes.md"] {
            files[rel] = try bytes(rel)
        }
        return files
    }

    private func expectUnchanged(_ before: [String: Data]) throws {
        for (rel, data) in before { #expect(try bytes(rel) == data, "\(rel) changed") }
        #expect(!exists("pnpm-lock.yaml"))
        #expect(!exists("pnpm-workspace.yaml"))
    }

    // MARK: - Convert

    @Test func convertHappyPath() throws {
        defer { tree.remove(); state.remove() }
        let recorder = StepRecorder()
        let result = try converter.convert(project, runBuildCheck: true) { recorder.record($0) }

        #expect(runner.calls == ["pnpm --version", "pnpm import", "pnpm install --frozen-lockfile", "pnpm run build"])
        #expect(recorder.steps == [.backingUp, .importing, .installing, .buildCheck, .rewritingConfigs, .cleaningUp])
        #expect(!exists("package-lock.json"))
        #expect(exists("pnpm-lock.yaml"))
        #expect(try String(contentsOf: tree.url("pnpm-workspace.yaml"), encoding: .utf8)
            == "onlyBuiltDependencies:\n  - '@prisma/engines'\n  - esbuild\n")
        #expect(try String(contentsOf: tree.url("package.json"), encoding: .utf8)
            == Self.packageJSON.replacingOccurrences(of: "npm run compile", with: "pnpm run compile"))
        #expect(try String(contentsOf: tree.url("notes.md"), encoding: .utf8) == "uncommitted work\n")

        let kinds = Dictionary(uniqueKeysWithValues: result.changes.map { ($0.relativePath, $0.kind) })
        #expect(kinds == [
            "package-lock.json": .deleted, "package.json": .modified, ".github/workflows/ci.yml": .modified,
            "pnpm-lock.yaml": .added, "pnpm-workspace.yaml": .added,
        ])
        let deleted = try #require(result.changes.first { $0.relativePath == "package-lock.json" })
        #expect(deleted.diff.contains("--- a/package-lock.json"))
        #expect(deleted.diff.contains("+++ /dev/null"))
        #expect(deleted.diff.contains("-  \"lockfileVersion\": 3,"))
        let added = try #require(result.changes.first { $0.relativePath == "pnpm-lock.yaml" })
        #expect(added.diff.contains("--- /dev/null"))
        #expect(added.diff.contains("+++ b/pnpm-lock.yaml"))
        #expect(added.diff.contains("+lockfileVersion: '9.0'"))
        let modified = try #require(result.changes.first { $0.relativePath == "package.json" })
        #expect(modified.diff.contains("-  \"scripts\": { \"build\": \"npm run compile\", \"compile\": \"tsc\" },"))
        #expect(modified.diff.contains("+  \"scripts\": { \"build\": \"pnpm run compile\", \"compile\": \"tsc\" },"))

        #expect(result.warnings == [Self.warning])
        #expect(result.pnpmVersion == "10.33.2")
        #expect(result.bytesFreed >= 80_000)
        #expect(ConversionBackup.latest(for: tree.root, paths: paths)?.id == result.backupID)
    }

    @Test func convertBacksUpEveryFileItMayChange() throws {
        defer { tree.remove(); state.remove() }
        let result = try converter.convert(project, runBuildCheck: false) { _ in }
        let backup = try #require(ConversionBackup.latest(for: tree.root, paths: paths))
        #expect(backup.id == result.backupID)
        #expect(backup.originalManager == .npm)
        #expect(backup.entries == [
            "package-lock.json": true, "package.json": true, "pnpm-lock.yaml": false,
            "pnpm-workspace.yaml": false, ".github/workflows/ci.yml": true,
        ])
    }

    @Test func convertFailureRevertsEverything() throws {
        defer { tree.remove(); state.remove() }
        runner.script("pnpm install --frozen-lockfile", exitCode: 1, stderr: "ERR_PNPM_FETCH_404 nope\n")
        let before = try snapshot()

        let failure = try #require(throws: ConversionFailure.self) {
            try converter.convert(project, runBuildCheck: true) { _ in }
        }
        #expect(failure.step == .installing)
        #expect(failure.reverted)
        #expect(failure.command == "pnpm install --frozen-lockfile")
        #expect(failure.output.contains("ERR_PNPM_FETCH_404 nope"))
        try expectUnchanged(before)
        #expect(runner.calls.last == "npm ci")
    }

    @Test func buildFailureRevertsEverything() throws {
        defer { tree.remove(); state.remove() }
        runner.script("pnpm run build", exitCode: 2, stdout: "tsc: error TS2304\n")
        let before = try snapshot()

        let failure = try #require(throws: ConversionFailure.self) {
            try converter.convert(project, runBuildCheck: true) { _ in }
        }
        #expect(failure.step == .buildCheck)
        #expect(failure.reverted)
        #expect(failure.output.contains("tsc: error TS2304"))
        try expectUnchanged(before)
        #expect(runner.calls.last == "npm ci")
    }

    @Test func importFailureRestoresWithoutTouchingNodeModules() throws {
        defer { tree.remove(); state.remove() }
        runner.script("pnpm import", exitCode: 1, stderr: "ERR_PNPM_LOCKFILE\n") { dir in
            try Data("partial".utf8).write(to: URL(fileURLWithPath: dir!.path + "/pnpm-lock.yaml"))
        }
        let before = try snapshot()

        let failure = try #require(throws: ConversionFailure.self) {
            try converter.convert(project, runBuildCheck: true) { _ in }
        }
        #expect(failure.step == .importing)
        #expect(failure.reverted)
        try expectUnchanged(before)
        // node_modules was never removed, so the original install is still in place.
        #expect(exists("node_modules/esbuild/main.js"))
        #expect(runner.calls == ["pnpm --version", "pnpm import"])
    }

    @Test func reinstallFailureStillRestoresFiles() throws {
        defer { tree.remove(); state.remove() }
        runner.script("pnpm install --frozen-lockfile", exitCode: 1, stderr: "pnpm broke\n")
        runner.script("npm ci", exitCode: 1, stderr: "npm ERR! network\n")
        let before = try snapshot()

        let failure = try #require(throws: ConversionFailure.self) {
            try converter.convert(project, runBuildCheck: true) { _ in }
        }
        #expect(failure.step == .installing)
        #expect(failure.reverted)
        #expect(failure.output.contains("pnpm broke"))
        #expect(failure.output.contains("npm ERR! network"))
        try expectUnchanged(before)
    }

    @Test func yarnFailureReinstallsWithYarn() throws {
        defer { tree.remove(); state.remove() }
        try FileManager.default.removeItem(at: tree.url("package-lock.json"))
        try tree.add(["yarn.lock": "# yarn lockfile v1\n"])
        runner.script("pnpm install --frozen-lockfile", exitCode: 1)
        let yarnProject = Project(root: tree.root, parentRoot: nil, packageManager: .yarn, nodeModules: nil)

        let failure = try #require(throws: ConversionFailure.self) {
            try converter.convert(yarnProject, runBuildCheck: false) { _ in }
        }
        #expect(failure.reverted)
        #expect(runner.calls.last == "yarn install --frozen-lockfile")
        #expect(try String(contentsOf: tree.url("yarn.lock"), encoding: .utf8) == "# yarn lockfile v1\n")
    }

    @Test func commandNotFoundIsAFailureThatReverts() throws {
        defer { tree.remove(); state.remove() }
        runner.script("pnpm install --frozen-lockfile") { _ in throw CommandRunnerError.commandNotFound("pnpm") }
        let before = try snapshot()

        let failure = try #require(throws: ConversionFailure.self) {
            try converter.convert(project, runBuildCheck: false) { _ in }
        }
        #expect(failure.step == .installing)
        #expect(failure.reverted)
        try expectUnchanged(before)
    }

    @Test func buildCheckSkippedWithoutBuildScript() throws {
        defer { tree.remove(); state.remove() }
        try tree.add(["package.json": #"{"name":"app","scripts":{"test":"node t.js"}}"#])
        _ = try PnpmConverter(runner: runner, paths: paths, rewriter: StubRewriter())
            .convert(project, runBuildCheck: true) { _ in }
        #expect(!runner.calls.contains("pnpm run build"))
    }

    @Test func buildCheckSkippedWhenNotRequested() throws {
        defer { tree.remove(); state.remove() }
        _ = try converter.convert(project, runBuildCheck: false) { _ in }
        #expect(!runner.calls.contains("pnpm run build"))
    }

    @Test func noBuildScriptsMeansNoWorkspaceFile() throws {
        defer { tree.remove(); state.remove() }
        try tree.add(["package-lock.json": #"{"lockfileVersion":3,"packages":{"":{},"node_modules/a":{}}}"#])
        let result = try converter.convert(project, runBuildCheck: false) { _ in }
        #expect(!exists("pnpm-workspace.yaml"))
        #expect(!result.changes.contains { $0.relativePath == "pnpm-workspace.yaml" })
    }

    @Test func unsupportedPnpmChangesNothing() throws {
        defer { tree.remove(); state.remove() }
        runner.script("pnpm --version", stdout: "9.15.0\n")
        let before = try snapshot()

        let failure = try #require(throws: ConversionFailure.self) {
            try converter.convert(project, runBuildCheck: true) { _ in }
        }
        #expect(failure.command == "pnpm --version")
        #expect(runner.calls == ["pnpm --version"])
        try expectUnchanged(before)
        #expect(ConversionBackup.latest(for: tree.root, paths: paths) == nil)
    }

    // MARK: - Revert

    @Test func revertRestoresEverything() throws {
        defer { tree.remove(); state.remove() }
        let before = try snapshot()
        let nodeModules = tree.url("node_modules").path
        let sawNodeModules = StepRecorder()
        runner.script("npm ci") { _ in
            if FileManager.default.fileExists(atPath: nodeModules) { sawNodeModules.record(.installing) }
        }
        _ = try converter.convert(project, runBuildCheck: false) { _ in }
        let pnpmProject = Project(root: tree.root, parentRoot: nil, packageManager: .pnpm, nodeModules: nil)
        let backup = try #require(ConversionBackup.latest(for: tree.root, paths: paths))

        try converter.revert(pnpmProject, backup: backup)

        try expectUnchanged(before)
        #expect(runner.calls.last == "npm ci")
        #expect(sawNodeModules.steps.isEmpty, "node_modules should be removed before reinstalling")
    }

    @Test func revertReinstallFailureThrows() throws {
        defer { tree.remove(); state.remove() }
        let before = try snapshot()
        _ = try converter.convert(project, runBuildCheck: false) { _ in }
        runner.script("npm ci", exitCode: 1, stderr: "npm ERR! offline\n")
        let backup = try #require(ConversionBackup.latest(for: tree.root, paths: paths))

        let failure = try #require(throws: ConversionFailure.self) {
            try converter.revert(project, backup: backup)
        }
        #expect(failure.command == "npm ci")
        #expect(failure.output.contains("npm ERR! offline"))
        try expectUnchanged(before)
    }

    // MARK: - Toolchain

    @Test func toolchainVersionGate() {
        defer { tree.remove(); state.remove() }
        let toolchain = PnpmToolchain(runner: runner)
        #expect(!toolchain.isSupported("9.15.0"))
        #expect(toolchain.isSupported("10.33.2"))
        #expect(toolchain.isSupported("11.0.0-rc.1"))
        #expect(!toolchain.isSupported(""))
        #expect(!toolchain.isSupported("garbage"))
        #expect(PnpmToolchain.minimumMajor == 10)
    }

    @Test func toolchainInstalledVersion() {
        defer { tree.remove(); state.remove() }
        runner.script("pnpm --version", stdout: "10.33.2\n")
        #expect(PnpmToolchain(runner: runner).installedVersion() == "10.33.2")

        let missing = FakeCommandRunner()
        missing.makeMissing("pnpm")
        #expect(PnpmToolchain(runner: missing).installedVersion() == nil)

        let failing = FakeCommandRunner()
        failing.script("pnpm --version", exitCode: 1, stderr: "boom")
        #expect(PnpmToolchain(runner: failing).installedVersion() == nil)
    }

    @Test func toolchainInstallFallsBack() throws {
        defer { tree.remove(); state.remove() }
        runner.script("corepack enable pnpm", exitCode: 1, stderr: "EACCES")
        let command = try PnpmToolchain(runner: runner).install()
        #expect(command == "npm install -g pnpm@latest")
        #expect(runner.calls == ["corepack enable pnpm", "npm install -g pnpm@latest"])
    }

    @Test func toolchainInstallPrefersCorepack() throws {
        defer { tree.remove(); state.remove() }
        let command = try PnpmToolchain(runner: runner).install()
        #expect(command == "corepack enable pnpm")
        #expect(runner.calls == ["corepack enable pnpm"])
    }

    @Test func toolchainInstallFallsBackWhenCorepackIsMissing() throws {
        defer { tree.remove(); state.remove() }
        runner.makeMissing("corepack")
        #expect(try PnpmToolchain(runner: runner).install() == "npm install -g pnpm@latest")
    }

    @Test func toolchainInstallThrowsWhenEverythingFails() {
        defer { tree.remove(); state.remove() }
        runner.script("corepack enable pnpm", exitCode: 1, stderr: "corepack said no")
        runner.script("npm install -g pnpm@latest", exitCode: 1, stderr: "npm said no")
        let error = #expect(throws: PnpmInstallError.self) { try PnpmToolchain(runner: runner).install() }
        #expect(error?.output.contains("corepack said no") == true)
        #expect(error?.output.contains("npm said no") == true)
    }

    // MARK: - Real pnpm

    @Test(
        .enabled(if: RealPnpm.available, "needs pnpm and npm on the login-shell PATH and the npm registry"),
        .timeLimit(.minutes(5)))
    func realPnpmIntegration() throws {
        defer { tree.remove(); state.remove() }
        let runner = RealPnpm.runner
        // Review Focus 1 and 4: login-shell PATH, and a project path with a space, unicode and a trailing space.
        let root = URL(fileURLWithPath: state.root.path + "/My Project café ", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = """
        {
          "name": "fw-integration",
          "version": "1.0.0",
          "private": true,
          "scripts": { "build": "node -e \\"require('is-number')\\"", "check": "npm run build" },
          "dependencies": { "is-number": "7.0.0" }
        }

        """
        try Data(manifest.utf8).write(to: URL(fileURLWithPath: root.path + "/package.json"))
        let npmInstall = try runner.run("npm", ["install", "--no-audit", "--no-fund"], in: root)
        try #require(npmInstall.succeeded, "\(npmInstall.stdout)\(npmInstall.stderr)")
        let lockPath = root.path + "/package-lock.json"
        let originalLock = try Data(contentsOf: URL(fileURLWithPath: lockPath))
        let project = Project(
            root: root, parentRoot: nil, packageManager: .npm,
            nodeModules: URL(fileURLWithPath: root.path + "/node_modules"))
        let originalManifest = try Data(contentsOf: URL(fileURLWithPath: root.path + "/package.json"))
        let converter = PnpmConverter(runner: runner, paths: paths, rewriter: ConfigRewriter())

        let result = try converter.convert(project, runBuildCheck: true) { _ in }

        #expect(FileManager.default.fileExists(atPath: root.path + "/pnpm-lock.yaml"))
        #expect(!FileManager.default.fileExists(atPath: lockPath))
        #expect(FileManager.default.fileExists(atPath: root.path + "/node_modules/is-number/package.json"))
        #expect(PnpmToolchain(runner: runner).isSupported(result.pnpmVersion))
        #expect(result.changes.contains { $0.relativePath == "pnpm-lock.yaml" && $0.kind == .added })
        #expect(try String(contentsOf: URL(fileURLWithPath: root.path + "/package.json"), encoding: .utf8)
            .contains("\"check\": \"pnpm run build\""))

        let backup = try #require(ConversionBackup.latest(for: root, paths: paths))
        try converter.revert(project, backup: backup)

        #expect(try Data(contentsOf: URL(fileURLWithPath: lockPath)) == originalLock)
        #expect(try Data(contentsOf: URL(fileURLWithPath: root.path + "/package.json")) == originalManifest)
        #expect(!FileManager.default.fileExists(atPath: root.path + "/pnpm-lock.yaml"))
        #expect(FileManager.default.fileExists(atPath: root.path + "/node_modules/is-number/package.json"))
        #expect(!FileManager.default.fileExists(atPath: root.path + "/node_modules/.pnpm"))
    }
}

/// Whether the real-tool integration test can run here.
enum RealPnpm {
    static let runner = ProcessCommandRunner()

    static let available: Bool = {
        func succeeds(_ command: String, _ args: [String]) -> Bool {
            (try? runner.run(command, args, in: nil))?.succeeded ?? false
        }
        return succeeds("pnpm", ["--version"]) && succeeds("npm", ["--version"])
            && succeeds("/usr/bin/curl", ["-sf", "-o", "/dev/null", "--max-time", "10", "https://registry.npmjs.org/is-number"])
    }()
}
