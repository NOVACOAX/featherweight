import Foundation

enum PhysicalPath {
    /// `path` with every symlink resolved (so `/var` and `/private/var` compare equal), or nil if
    /// it does not exist.
    static func resolve(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
