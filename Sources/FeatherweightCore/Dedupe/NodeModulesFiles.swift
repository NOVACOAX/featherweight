import Foundation
import os

/// A regular file found under a project's `node_modules`.
struct NodeModulesFile {
    let url: URL
    /// Index of the owning project in the array passed to `NodeModulesFiles.forEach`.
    let project: Int
    let info: CloneInfo
}

enum NodeModulesFiles {
    /// Whether a file may take part in block sharing: a non-empty regular file with one link.
    static func isCandidate(_ info: CloneInfo) -> Bool {
        info.isRegularFile && info.size > 0 && info.linkCount == 1
    }

    /// Calls `body` for every regular file under the projects' `node_modules` folders, without
    /// following symlinks. A `node_modules` equal to or inside one already listed is skipped, so
    /// each file is visited once and belongs to the outermost project. Unreadable entries are
    /// passed to `onError` as "path: error".
    static func forEach(
        in projects: [Project], onError: (String) -> Void, _ body: (NodeModulesFile) -> Void
    ) {
        let roots = projects.enumerated()
            .compactMap { index, project in project.nodeModules.map { (index, $0.path) } }
            .sorted { $0.1 < $1.1 }
        var visited: [String] = []
        for (index, path) in roots {
            if visited.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { continue }
            visited.append(path)
            walk(URL(fileURLWithPath: path, isDirectory: true), project: index, onError: onError, body)
        }
    }

    /// How many times each `node_modules` folder (by path) has been walked in this process. Walks
    /// are the helper's main cost, so tests use this to pin how many a job makes.
    private static let walkCounts = OSAllocatedUnfairLock(initialState: [String: Int]())

    static func walks(of path: String) -> Int {
        walkCounts.withLock { $0[path, default: 0] }
    }

    private static func walk(
        _ directory: URL, project: Int, onError: (String) -> Void, _ body: (NodeModulesFile) -> Void
    ) {
        walkCounts.withLock { $0[directory.path, default: 0] += 1 }
        // The enumerator's handler escapes, so its errors are collected and reported afterwards.
        var walkErrors: [String] = []
        let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [],
            errorHandler: { url, error in
                walkErrors.append("\(url.path): \(error.localizedDescription)")
                return true
            })
        walker?.forEachURL { url in
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return true }
            do {
                let info = try CloneFS.info(at: url)
                if info.isRegularFile { body(NodeModulesFile(url: url, project: project, info: info)) }
            } catch {
                onError("\(url.path): \(error)")
            }
            return true
        }
        walkErrors.forEach(onError)
    }
}
