import Foundation

public enum PackageManager: String, Codable, Sendable {
    case npm, pnpm, yarn, bun, none
}

public struct Project: Hashable, Codable, Sendable {
    public let root: URL
    /// Root of the nearest enclosing project, if this project is nested inside another.
    public let parentRoot: URL?
    public let packageManager: PackageManager
    public var nodeModules: URL?

    public init(root: URL, parentRoot: URL?, packageManager: PackageManager, nodeModules: URL?) {
        self.root = root
        self.parentRoot = parentRoot
        self.packageManager = packageManager
        self.nodeModules = nodeModules
    }
}

public enum PackageManagerDetector {
    public static func detect(root: URL) -> PackageManager {
        let fm = FileManager.default
        func has(_ name: String) -> Bool {
            fm.fileExists(atPath: root.appendingPathComponent(name).path)
        }
        if has("package-lock.json") || has("npm-shrinkwrap.json") { return .npm }
        if has("pnpm-lock.yaml") { return .pnpm }
        if has("yarn.lock") { return .yarn }
        if has("bun.lock") || has("bun.lockb") { return .bun }
        return .none
    }
}
