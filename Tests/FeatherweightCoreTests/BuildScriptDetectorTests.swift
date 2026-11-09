import Foundation
import Testing
@testable import FeatherweightCore

struct BuildScriptDetectorTests {
    @Test func detectorReadsLockfileFlags() throws {
        let lock = """
        {
          "name": "app",
          "lockfileVersion": 3,
          "packages": {
            "": { "name": "app", "hasInstallScript": true },
            "node_modules/esbuild": { "version": "0.21.5", "hasInstallScript": true },
            "node_modules/@prisma/engines": { "version": "5.0.0", "hasInstallScript": true },
            "node_modules/vite/node_modules/esbuild": { "version": "0.20.0", "hasInstallScript": true },
            "node_modules/is-number": { "version": "7.0.0" },
            "node_modules/left-pad": { "version": "1.3.0", "hasInstallScript": false }
          }
        }
        """
        let tree = try TempTree([
            "package.json": "{}", "package-lock.json": lock,
            // Ignored: the lockfile is authoritative for npm.
            "node_modules/sharp/package.json": #"{"scripts":{"install":"node install.js"}}"#,
        ])
        defer { tree.remove() }
        #expect(BuildScriptDetector().packagesWithInstallScripts(root: tree.root) == ["@prisma/engines", "esbuild"])
    }

    @Test func detectorFallsBackToNodeModules() throws {
        let tree = try TempTree([
            "package.json": "{}", "yarn.lock": "",
            "node_modules/sharp/package.json": #"{"name":"sharp","scripts":{"install":"node install.js"}}"#,
            "node_modules/is-number/package.json": #"{"name":"is-number","scripts":{"test":"mocha"}}"#,
        ])
        defer { tree.remove() }
        #expect(BuildScriptDetector().packagesWithInstallScripts(root: tree.root) == ["sharp"])
    }

    @Test func detectorFallbackFindsScopedHooksAndBindingGyp() throws {
        let tree = try TempTree([
            "package.json": "{}", "yarn.lock": "",
            "node_modules/@scope/pre/package.json": #"{"scripts":{"preinstall":"x"}}"#,
            "node_modules/@scope/post/package.json": #"{"scripts":{"postinstall":"x"}}"#,
            "node_modules/@scope/plain/package.json": #"{"scripts":{}}"#,
            "node_modules/native/package.json": #"{"name":"native"}"#,
            "node_modules/native/binding.gyp": "{}",
            "node_modules/.bin/": "",
        ])
        defer { tree.remove() }
        #expect(BuildScriptDetector().packagesWithInstallScripts(root: tree.root)
            == ["@scope/post", "@scope/pre", "native"])
    }

    @Test func detectorFallsBackWhenLockfileHasNoPackagesMap() throws {
        let tree = try TempTree([
            "package.json": "{}", "package-lock.json": #"{"lockfileVersion":1,"dependencies":{}}"#,
            "node_modules/sharp/package.json": #"{"scripts":{"install":"node install.js"}}"#,
        ])
        defer { tree.remove() }
        #expect(BuildScriptDetector().packagesWithInstallScripts(root: tree.root) == ["sharp"])
    }

    @Test func detectorFindsNothingWithoutNodeModules() throws {
        let tree = try TempTree(["package.json": "{}", "yarn.lock": ""])
        defer { tree.remove() }
        #expect(BuildScriptDetector().packagesWithInstallScripts(root: tree.root) == [])
    }
}
