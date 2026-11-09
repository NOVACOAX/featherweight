import Foundation

/// Finds the dependencies that run install scripts, so pnpm can be told to keep building them
/// (`onlyBuiltDependencies`) the way npm and yarn did.
public struct BuildScriptDetector: Sendable {
    private static let installHooks = ["preinstall", "install", "postinstall"]

    public init() {}

    /// Package names, sorted and unique. Reads npm's lockfile (`package-lock.json` or
    /// `npm-shrinkwrap.json`) when it has a `packages` map, otherwise the packages installed at the
    /// top of `node_modules`.
    public func packagesWithInstallScripts(root: URL) -> [String] {
        let names = fromLockfile(root: root, name: "package-lock.json")
            ?? fromLockfile(root: root, name: "npm-shrinkwrap.json")
            ?? fromNodeModules(root: root)
        return Array(Set(names)).sorted()
    }

    private func fromLockfile(root: URL, name: String) -> [String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: root.path + "/" + name)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let packages = json["packages"] as? [String: Any] else { return nil }
        let marker = "node_modules/"
        return packages.compactMap { key, value in
            guard (value as? [String: Any])?["hasInstallScript"] as? Bool == true,
                  let range = key.range(of: marker, options: .backwards) else { return nil }
            let name = String(key[range.upperBound...])
            return name.isEmpty ? nil : name
        }
    }

    private func fromNodeModules(root: URL) -> [String] {
        let nodeModules = root.path + "/node_modules"
        var names: [String] = []
        for entry in visibleEntries(nodeModules) {
            if entry.hasPrefix("@") {
                for child in visibleEntries(nodeModules + "/" + entry)
                where runsInstallScript(nodeModules + "/" + entry + "/" + child) {
                    names.append(entry + "/" + child)
                }
            } else if runsInstallScript(nodeModules + "/" + entry) {
                names.append(entry)
            }
        }
        return names
    }

    private func visibleEntries(_ directory: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).filter { !$0.hasPrefix(".") }
    }

    /// npm runs `node-gyp rebuild` for a package with a `binding.gyp` and no install script.
    private func runsInstallScript(_ packageDirectory: String) -> Bool {
        if FileManager.default.fileExists(atPath: packageDirectory + "/binding.gyp") { return true }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: packageDirectory + "/package.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = json["scripts"] as? [String: Any] else { return false }
        return Self.installHooks.contains { (scripts[$0] as? String)?.isEmpty == false }
    }
}
