import CryptoKit
import Darwin
import Foundation

public enum ConversionBackupError: Error, Equatable {
    /// A relative path that is empty, absolute or climbs out of the project with `..`.
    case invalidRelativePath(String)
}

/// Copies of every project file a pnpm conversion may change, so it can be undone byte-for-byte.
/// Stored at `backups/<sha256(project path) prefix 16>/<id>/`, with a `manifest.json` and the
/// copies under `files/`.
public struct ConversionBackup: Codable, Sendable, Equatable {
    public let id: UUID
    /// The project's physical path (symlinks resolved).
    public let projectRoot: String
    public let createdAt: Date
    public let originalManager: PackageManager
    /// Relative path → whether the file existed when the backup was made.
    public let entries: [String: Bool]

    /// Copies each of `relativePaths` that exists under `root` and records the ones that don't.
    /// Nothing in the project is changed. A partial backup is removed if anything fails.
    public static func create(
        root: URL, relativePaths: [String], manager: PackageManager, paths: AppPaths
    ) throws -> ConversionBackup {
        for relativePath in relativePaths where !isSafe(relativePath) {
            throw ConversionBackupError.invalidRelativePath(relativePath)
        }
        let projectRoot = physicalPath(root)
        var backup = ConversionBackup(
            id: UUID(), projectRoot: projectRoot, createdAt: Date(), originalManager: manager, entries: [:])
        let fileManager = FileManager.default
        let folder = backup.folder(paths)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            var entries: [String: Bool] = [:]
            for relativePath in relativePaths {
                let source = projectRoot + "/" + relativePath
                guard itemExists(source) else {
                    entries[relativePath] = false
                    continue
                }
                let copy = backup.storedFile(relativePath, paths: paths)
                try fileManager.createDirectory(
                    atPath: (copy as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try fileManager.copyItem(atPath: source, toPath: copy)
                entries[relativePath] = true
            }
            backup = ConversionBackup(
                id: backup.id, projectRoot: projectRoot, createdAt: backup.createdAt, originalManager: manager,
                entries: entries)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(backup).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
            return backup
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
    }

    /// Puts back every file that existed, byte-for-byte (atomically, with its permissions), and
    /// deletes every recorded file that didn't. Other files in the project are not touched. Keeps
    /// going after an error so as much as possible is restored, then throws the first error.
    public func restore(paths: AppPaths) throws {
        var firstError: (any Error)?
        for (relativePath, existed) in entries.sorted(by: { $0.key < $1.key }) {
            let target = projectRoot + "/" + relativePath
            do {
                if existed {
                    try Self.replace(target, withCopyOf: storedFile(relativePath, paths: paths))
                } else if Self.itemExists(target) {
                    try FileManager.default.removeItem(atPath: target)
                }
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    /// The most recent backup of the project at `root`, or nil if there is none.
    public static func latest(for root: URL, paths: AppPaths) -> ConversionBackup? {
        let projectRoot = physicalPath(root)
        let projectFolder = paths.backups.appendingPathComponent(folderKey(projectRoot), isDirectory: true)
        guard let ids = try? FileManager.default.contentsOfDirectory(atPath: projectFolder.path) else { return nil }
        let decoder = JSONDecoder()
        return ids
            .compactMap { id -> ConversionBackup? in
                let manifest = projectFolder.appendingPathComponent(id).appendingPathComponent("manifest.json")
                guard let data = try? Data(contentsOf: manifest) else { return nil }
                return try? decoder.decode(ConversionBackup.self, from: data)
            }
            .filter { $0.projectRoot == projectRoot }
            .max { $0.createdAt < $1.createdAt }
    }

    /// The saved copy of `relativePath` (meaningful only when `entries[relativePath] == true`).
    func storedFile(_ relativePath: String, paths: AppPaths) -> String {
        folder(paths).path + "/files/" + relativePath
    }

    private func folder(_ paths: AppPaths) -> URL {
        paths.backups
            .appendingPathComponent(Self.folderKey(projectRoot), isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private static func folderKey(_ projectRoot: String) -> String {
        String(SHA256.hash(data: Data(projectRoot.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    private static func physicalPath(_ root: URL) -> String {
        PhysicalPath.resolve(root.path) ?? root.path
    }

    private static func isSafe(_ relativePath: String) -> Bool {
        !relativePath.isEmpty && !relativePath.hasPrefix("/")
            && !relativePath.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    /// True if anything (even a dangling symlink) is at `path`.
    private static func itemExists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    /// Copies `source` next to `target`, then renames it over `target`, so `target` is never missing
    /// or half-written.
    private static func replace(_ target: String, withCopyOf source: String) throws {
        let fileManager = FileManager.default
        let directory = (target as NSString).deletingLastPathComponent
        try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let temporary = directory + "/." + (target as NSString).lastPathComponent + ".fw-restore-" + UUID().uuidString
        try fileManager.copyItem(atPath: source, toPath: temporary)
        if rename(temporary, target) != 0 {
            let code = errno
            unlink(temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}
