import Foundation

/// A quick, read-only guess at what sharing duplicates would save, for the first launch screen.
///
/// It never reads file contents, so it takes seconds rather than the minutes a real sweep spends
/// hashing. Files count as copies of each other when they have the same path inside
/// `node_modules` (for example `react/index.js`) and the same size, which is how one package
/// version shows up across projects. Files that already share all their blocks count once.
public enum DuplicateEstimate {
    private struct Key: Hashable {
        let device: UInt64
        let size: Int64
        let packagePath: Int
    }

    private struct Group {
        var allocated: Int64 = 0
        var unshared = 0
        var cloneIDs: [UInt64] = []

        var copies: Int { unshared + cloneIDs.count }
    }

    /// Bytes a sweep would roughly free across `projects`.
    public static func bytes(projects: [Project]) -> Int64 {
        var groups: [Key: Group] = [:]
        NodeModulesFiles.forEach(in: projects, onError: { _ in }) { file in
            guard NodeModulesFiles.isCandidate(file.info),
                  let packagePath = packagePath(of: file.url.path)
            else { return }
            let key = Key(device: file.info.device, size: file.info.size, packagePath: packagePath.hashValue)
            var group = groups[key] ?? Group()
            group.allocated = max(group.allocated, file.info.allocatedSize)
            if file.info.sharesAllBlocks {
                if !group.cloneIDs.contains(file.info.cloneID) { group.cloneIDs.append(file.info.cloneID) }
            } else {
                group.unshared += 1
            }
            groups[key] = group
        }
        return groups.values.reduce(0) { total, group in
            total + Int64(max(0, group.copies - 1)) * group.allocated
        }
    }

    /// The part of `path` after its last `/node_modules/`, or nil outside one.
    static func packagePath(of path: String) -> Substring? {
        guard let marker = path.range(of: "/node_modules/", options: .backwards) else { return nil }
        return path[marker.upperBound...]
    }
}
