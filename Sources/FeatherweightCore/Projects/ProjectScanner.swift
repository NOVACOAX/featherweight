import Foundation

/// Finds JavaScript projects (directories containing `package.json`) under a set of folders.
///
/// Never descends into `node_modules`, `.git`, the excluded directory names, symlinked
/// directories, or Python virtual environments (`.venv`, `venv`, or any directory
/// containing `pyvenv.cfg`).
///
/// It also never enters the iCloud and cloud-storage folders under the home folder
/// (`Library/Mobile Documents`, `Library/CloudStorage`) or any folder iCloud manages, even when a
/// folder above them was chosen: offloaded files would need downloading.
public struct ProjectScanner: Sendable {
    public let excludedDirectoryNames: Set<String>
    /// Lower-cased physical paths of the sync folders that are never entered.
    private let syncRoots: [String]

    /// Folders that tools generate deploy and framework output into. A `package.json` in there
    /// belongs to the output, not to a project. (Skipped for discovery only: whether their
    /// contents may be cleared is up to the cache folder settings.)
    public static let generatedOutputDirectories: Set<String> = [
        ".vercel", ".netlify", ".svelte-kit", ".wrangler", ".firebase", ".expo",
    ]

    /// Directory names to skip when scanning for `settings`: cache folder names without a "/" (so
    /// their contents are not mistaken for projects) and the generated output folders.
    public static func excludedNames(for settings: Settings) -> Set<String> {
        Set(settings.cacheFolders.map(\.relativePath).filter { !$0.contains("/") })
            .union(generatedOutputDirectories)
    }

    /// `home` is where the sync folders are looked for; it is a parameter so tests need not depend
    /// on the real home folder.
    public init(
        excludedDirectoryNames: Set<String>,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.excludedDirectoryNames = excludedDirectoryNames
        // The home folder under every spelling a path below it may come in (`/private/var/...` and
        // the `/var/...` that Foundation's symlink resolution gives).
        let homes = Set([
            PhysicalPath.resolve(home.path), home.resolvingSymlinksInPath().path, home.standardizedFileURL.path,
        ].compactMap { $0 })
        syncRoots = homes.flatMap { home in
            ["Library/Mobile Documents", "Library/CloudStorage"].map { (home + "/" + $0).lowercased() }
        }
    }

    private func isSyncRoot(_ path: String) -> Bool {
        syncRoots.contains(path.lowercased())
    }

    private func isInsideSyncRoot(_ path: String) -> Bool {
        let lowered = path.lowercased()
        return syncRoots.contains { lowered == $0 || lowered.hasPrefix($0 + "/") }
    }

    /// Canonical form for every URL we hand out: a standardized directory file URL built from
    /// the plain path, so `Project` values compare equal regardless of discovery path.
    private static func canonical(_ url: URL) -> URL {
        URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
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
                let nm = Self.canonical(root.appendingPathComponent("node_modules", isDirectory: true))
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

    private func findProjectRoots(in rawFolder: URL) -> [URL] {
        let fm = FileManager.default
        // Resolve only the top-level folder (a symlinked scan folder would otherwise enumerate
        // as empty). Nested symlinks are still never followed.
        let folder = Self.canonical(rawFolder.resolvingSymlinksInPath())
        if isInsideSyncRoot(folder.path) { return [] }
        var found: [URL] = []
        // The folder itself may be a project (it is never yielded by the enumerator).
        if fm.fileExists(atPath: folder.appendingPathComponent("package.json").path),
           !fm.fileExists(atPath: folder.appendingPathComponent("pyvenv.cfg").path) {
            found.append(folder)
        }
        // Cheap keys the enumerator reads in bulk. `isUbiquitousItem` goes through FileProvider, so
        // it is asked only for folders that are not skipped by name, never for every file.
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
        guard let enumerator = fm.enumerator(
            at: folder, includingPropertiesForKeys: keys, options: []
        ) else { return found }
        enumerator.forEachURL { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return true }
            if values.isSymbolicLink == true { return true }  // never follow symlinks
            if values.isDirectory == true {
                if isSkippedDirectory(url, name: url.lastPathComponent) || isSyncRoot(url.path)
                    || (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true {
                    enumerator.skipDescendants()
                }
            } else if url.lastPathComponent == "package.json", values.isRegularFile == true {
                found.append(Self.canonical(url.deletingLastPathComponent()))
            }
            return true
        }
        return found
    }
}
