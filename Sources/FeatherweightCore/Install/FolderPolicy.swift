import Foundation

public enum FolderVerdict: Equatable, Sendable {
    /// The folder can be managed.
    case ok
    /// A privacy-protected folder (Desktop, Documents, Downloads) that this process cannot read yet.
    case needsAccess
    /// A folder that iCloud Drive or another sync service keeps in step with the cloud.
    case rejectedSync
}

/// Decides whether a folder may be added as a projects folder.
///
/// Offloaded files in a synced folder would need downloading, and every change Featherweight makes
/// would sync again, so those folders are refused. Desktop, Documents and Downloads ask the user for
/// permission, for both the app and the helper.
public struct FolderPolicy: Sendable {
    private let home: URL

    public init(home: URL) {
        self.home = home
    }

    /// Blocks while the system asks for access to a protected folder, so call it off the main thread.
    public func evaluate(_ url: URL) -> FolderVerdict {
        let homePath = Self.physicalPath(home.path)
        let path = Self.physicalPath(url.path)

        for root in ["Library/Mobile Documents", "Library/CloudStorage"]
        where Self.isInside(path, root: homePath + "/" + root) {
            return .rejectedSync
        }
        if isSynced(path: path, homePath: homePath) { return .rejectedSync }

        for name in ["Desktop", "Documents", "Downloads"] where Self.isInside(path, root: homePath + "/" + name) {
            do {
                _ = try FileManager.default.contentsOfDirectory(atPath: path)
            } catch where Self.isPermissionError(error) {
                return .needsAccess
            } catch {
                return .ok
            }
        }
        return .ok
    }

    /// Checks folders that were not picked through the folder panel, such as the default
    /// `~/Developer`: those that pass (as given) and those that do not, with why.
    /// Blocks like `evaluate`, so call it off the main thread.
    public func vet(_ folders: [String]) -> (usable: [String], refused: [(path: String, verdict: FolderVerdict)]) {
        var usable: [String] = []
        var refused: [(path: String, verdict: FolderVerdict)] = []
        for folder in folders {
            let verdict = evaluate(URL(fileURLWithPath: folder, isDirectory: true))
            if verdict == .ok { usable.append(folder) } else { refused.append((folder, verdict)) }
        }
        return (usable, refused)
    }

    /// True when the folder, or a folder above it inside the home folder, is an iCloud item.
    private func isSynced(path: String, homePath: String) -> Bool {
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey]
        var current = URL(fileURLWithPath: path)
        let stopAt = Self.isInside(path, root: homePath) ? homePath : nil
        while current.path != "/", current.path != stopAt {
            if let values = try? current.resourceValues(forKeys: keys),
               values.isUbiquitousItem == true || values.ubiquitousItemIsUploaded == true {
                return true
            }
            if stopAt == nil { break }
            current.deleteLastPathComponent()
        }
        return false
    }

    /// `path` with symlinks resolved as far as it exists, so a folder that is not there yet (or a
    /// link into a synced folder) is judged by where it really is.
    private static func physicalPath(_ path: String) -> String {
        var existing = URL(fileURLWithPath: path).standardizedFileURL
        var missing: [String] = []
        while existing.path != "/", PhysicalPath.resolve(existing.path) == nil {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        let base = PhysicalPath.resolve(existing.path) ?? existing.path
        return missing.isEmpty ? base : (base == "/" ? "" : base) + "/" + missing.joined(separator: "/")
    }

    /// Whether `path` is `root` or inside it. Case-insensitive, like the default macOS volume.
    private static func isInside(_ path: String, root: String) -> Bool {
        let path = path.lowercased()
        let root = root.lowercased()
        return path == root || path.hasPrefix(root + "/")
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoPermissionError { return true }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(EACCES) || error.code == Int(EPERM) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isPermissionError(underlying)
        }
        return false
    }
}
