import Foundation

/// Cheap recent-activity checks over a project tree. Symlinks are never followed.
public struct ActivityChecker: Sendable {
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    /// True if any regular file under `root` (excluding `.git`) has an mtime within `window`.
    /// Stops at the first recent file.
    public func isActive(root: URL, window: TimeInterval) -> Bool {
        let cutoff = now().addingTimeInterval(-window)
        var active = false
        walk(root: root, skipNames: [".git"]) { mtime in
            if mtime >= cutoff { active = true; return false }
            return true
        }
        return active
    }

    /// Newest regular-file mtime under `root`, excluding `node_modules` and `.git`.
    public func lastSourceChange(root: URL) -> Date? {
        var newest: Date?
        walk(root: root, skipNames: ["node_modules", ".git"]) { mtime in
            if newest == nil || mtime > newest! { newest = mtime }
            return true
        }
        return newest
    }

    /// Visits regular files; `visit` returns false to stop the walk.
    private func walk(root: URL, skipNames: Set<String>, visit: (Date) -> Bool) {
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .contentModificationDateKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: []
        ) else { return }
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true {
                if skipNames.contains(url.lastPathComponent) { enumerator.skipDescendants() }
            } else if values.isRegularFile == true, let mtime = values.contentModificationDate {
                if !visit(mtime) { return }
            }
        }
    }
}
