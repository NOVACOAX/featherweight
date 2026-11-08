import Foundation

/// Finds JavaScript projects (directories containing `package.json`) under a set of folders.
///
/// Never descends into `node_modules`, `.git`, the excluded directory names, symlinked
/// directories, or Python virtual environments (`.venv`, `venv`, or any directory
/// containing `pyvenv.cfg`).
public struct ProjectScanner: Sendable {
    public let excludedDirectoryNames: Set<String>

    public init(excludedDirectoryNames: Set<String>) {
        self.excludedDirectoryNames = excludedDirectoryNames
    }

    public func scan(folders: [URL]) -> [Project] {
        var roots = Set<String>()
        var rootURLs: [String: URL] = [:]
        for folder in folders {
            for url in findProjectRoots(in: folder) where roots.insert(url.path).inserted {
                rootURLs[url.path] = url
            }
        }
        let fm = FileManager.default
        return rootURLs.values
            .sorted { $0.path < $1.path }
            .map { root in
                let nm = root.appendingPathComponent("node_modules", isDirectory: true)
                var isDir: ObjCBool = false
                let hasNM = fm.fileExists(atPath: nm.path, isDirectory: &isDir) && isDir.boolValue
                return Project(
                    root: root,
                    parentRoot: nearestAncestor(of: root, in: roots, urls: rootURLs),
                    packageManager: PackageManagerDetector.detect(root: root),
                    nodeModules: hasNM ? nm : nil)
            }
    }

    private func nearestAncestor(of root: URL, in roots: Set<String>, urls: [String: URL]) -> URL? {
        var current = root
        while true {
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path || parent.path == "/" { return nil }
            if roots.contains(parent.path) { return urls[parent.path] }
            current = parent
        }
    }

    private func isSkippedDirectory(_ url: URL, name: String) -> Bool {
        if name == "node_modules" || name == ".git" || name == ".venv" || name == "venv" { return true }
        if excludedDirectoryNames.contains(name) { return true }
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("pyvenv.cfg").path)
    }

    private func findProjectRoots(in folder: URL) -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        // The folder itself may be a project (it is never yielded by the enumerator).
        if fm.fileExists(atPath: folder.appendingPathComponent("package.json").path),
           !fm.fileExists(atPath: folder.appendingPathComponent("pyvenv.cfg").path) {
            found.append(folder)
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
        guard let enumerator = fm.enumerator(
            at: folder, includingPropertiesForKeys: keys, options: []
        ) else { return found }
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true { continue }  // never follow symlinks
            if values.isDirectory == true {
                if isSkippedDirectory(url, name: url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
            } else if values.isRegularFile == true, url.lastPathComponent == "package.json" {
                found.append(url.deletingLastPathComponent())
            }
        }
        return found
    }
}
