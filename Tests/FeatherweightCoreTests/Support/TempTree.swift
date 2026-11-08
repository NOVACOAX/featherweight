import Foundation

/// Test helper that builds a file tree in a unique temp directory.
/// Keys of the `files` map are relative paths; a key ending in "/" creates an empty directory.
struct TempTree {
    let root: URL

    init(_ files: [String: String] = [:]) throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("featherweight-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Resolve /var -> /private/var so paths compare equal to enumerator output.
        root = base.resolvingSymlinksInPath()
        try add(files)
    }

    /// Adds files (relative path -> contents), creating parent directories as needed.
    func add(_ files: [String: String]) throws {
        for (path, contents) in files {
            let url = self.url(path)
            if path.hasSuffix("/") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(contents.utf8).write(to: url)
            }
        }
    }

    /// URL for a relative path inside the tree. Preserves trailing spaces in names.
    func url(_ relativePath: String = "") -> URL {
        relativePath.isEmpty ? root : URL(fileURLWithPath: root.path + "/" + relativePath)
    }

    /// Sets the modification time of the item at `relativePath`.
    func setMTime(_ relativePath: String, to date: Date) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date], ofItemAtPath: url(relativePath).path)
    }

    /// Sets the modification time of every regular file in the tree.
    func setAllMTimes(to date: Date) throws {
        let e = FileManager.default.enumerator(atPath: root.path)!
        for case let rel as String in e {
            try setMTime(rel, to: date)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
