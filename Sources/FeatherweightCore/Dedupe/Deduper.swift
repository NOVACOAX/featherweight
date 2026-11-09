import Foundation

public struct DedupeReport: Codable, Sendable, Equatable {
    /// Regular files examined under the projects' `node_modules` folders.
    public var filesScanned: Int
    /// Duplicates replaced with clones (or, in a dry run, that would have been).
    public var filesReplaced: Int
    public var bytesFreed: Int64
    /// Bytes freed per project root path, credited to the project of each replaced file.
    public var perProject: [String: Int64]
    /// One "path: error" line per file that could not be read, hashed or replaced.
    public var errors: [String]

    public init(
        filesScanned: Int = 0, filesReplaced: Int = 0, bytesFreed: Int64 = 0,
        perProject: [String: Int64] = [:], errors: [String] = []
    ) {
        self.filesScanned = filesScanned
        self.filesReplaced = filesReplaced
        self.bytesFreed = bytesFreed
        self.perProject = perProject
        self.errors = errors
    }
}

/// Replaces identical files across projects' `node_modules` with APFS clones of one keeper.
public struct Deduper: Sendable {
    private let hashCache: HashCache
    private let quietPeriod: TimeInterval
    private let now: @Sendable () -> Date

    /// Test hook: called after each (device, size) group is hashed, before any of its files are
    /// replaced.
    var afterHashing: (@Sendable () -> Void)?

    public init(
        hashCache: HashCache, quietPeriod: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.hashCache = hashCache
        self.quietPeriod = quietPeriod
        self.now = now
    }

    /// Shares identical files under the projects' `node_modules`, at background QoS with
    /// throttled disk I/O. With `dryRun`, reports what would be shared without changing anything.
    /// Files modified within the quiet period, empty files and hard-linked files are left alone.
    public func run(projects: [Project], dryRun: Bool) -> DedupeReport {
        BackgroundWork.run { sweep(projects: projects, dryRun: dryRun) }
    }

    // MARK: - Sweep

    private struct SizeKey: Hashable, Comparable {
        let device: UInt64
        let size: Int64
        static func < (a: SizeKey, b: SizeKey) -> Bool { (a.device, a.size) < (b.device, b.size) }
    }

    private struct Member {
        let path: String
        let project: Int
        /// Facts at collection time, then the facts the digest was computed from.
        let info: CloneInfo
        var url: URL { URL(fileURLWithPath: path) }
    }

    /// A keeper or duplicate changed after hashing; raised from `beforeRename`.
    private enum Changed: Error { case keeper, duplicate }

    private func sweep(projects: [Project], dryRun: Bool) -> DedupeReport {
        var report = DedupeReport()
        let start = now()
        func isQuiet(_ info: CloneInfo) -> Bool {
            let mtime = Date(timeIntervalSince1970: Double(info.mtimeNanos) / 1_000_000_000)
            return start.timeIntervalSince(mtime) >= quietPeriod
        }

        var bySize: [SizeKey: [Member]] = [:]
        var errors: [String] = []
        NodeModulesFiles.forEach(in: projects, onError: { errors.append($0) }) { file in
            report.filesScanned += 1
            guard NodeModulesFiles.isCandidate(file.info), isQuiet(file.info) else { return }
            bySize[SizeKey(device: file.info.device, size: file.info.size), default: []]
                .append(Member(path: file.url.path, project: file.project, info: file.info))
        }
        report.errors = errors
        bySize = bySize.filter { $0.value.count > 1 }

        for key in bySize.keys.sorted() {
            guard let members = bySize.removeValue(forKey: key) else { continue }
            var byDigest: [Data: [Member]] = [:]
            for member in members {
                do {
                    // HashCache trusts the info it is given, so read it fresh right before hashing.
                    let fresh = try CloneFS.info(at: member.url)
                    guard NodeModulesFiles.isCandidate(fresh), isQuiet(fresh),
                          fresh.device == key.device, fresh.size == key.size else { continue }
                    let digest = try hashCache.digest(for: member.url, info: fresh)
                    byDigest[digest, default: []]
                        .append(Member(path: member.path, project: member.project, info: fresh))
                } catch {
                    report.errors.append("\(member.path): \(error)")
                }
            }
            afterHashing?()
            let groups = byDigest.values.filter { $0.count > 1 }.map { $0.sorted { $0.path < $1.path } }
            for group in groups.sorted(by: { $0[0].path < $1[0].path }) {
                share(group, projects: projects, dryRun: dryRun, into: &report)
            }
        }
        return report
    }

    /// Replaces every member of a group of identical files (sorted by path) with a clone of the
    /// keeper, skipping members already sharing the keeper's blocks.
    private func share(_ group: [Member], projects: [Project], dryRun: Bool, into report: inout DedupeReport) {
        let keeper = Self.keeper(of: group)
        let keeperURL = keeper.url
        for member in group where member.path != keeper.path {
            if keeper.info.sharesAllBlocks, member.info.sharesAllBlocks,
               member.info.cloneID == keeper.info.cloneID { continue }

            do {
                guard try Self.isUnchanged(keeperURL, since: keeper.info) else { return }
            } catch {
                report.errors.append("\(keeper.path): \(error)")
                return
            }
            let current: CloneInfo
            do {
                current = try CloneFS.info(at: member.url)
            } catch {
                report.errors.append("\(member.path): \(error)")
                continue
            }
            guard Self.sameContentsKey(current, member.info) else { continue }

            if !dryRun {
                do {
                    try CloneFS.replaceWithClone(of: keeperURL, replacing: member.url, beforeRename: {
                        guard try Self.isUnchanged(keeperURL, since: keeper.info) else { throw Changed.keeper }
                        guard try Self.isUnchanged(member.url, since: member.info) else { throw Changed.duplicate }
                    })
                } catch Changed.keeper {
                    return
                } catch Changed.duplicate, CloneError.changedDuringReplace,
                        CloneError.hardlinked, CloneError.compressed, CloneError.sameFile {
                    continue
                } catch {
                    report.errors.append("\(member.path): \(error)")
                    continue
                }
            }
            report.filesReplaced += 1
            report.bytesFreed += current.privateSize
            report.perProject[projects[member.project].root.path, default: 0] += current.privateSize
        }
    }

    /// The member whose blocks the others should share: one with the most common `cloneID` among
    /// members that share all their blocks, else any member; ties go to the smallest path.
    private static func keeper(of group: [Member]) -> Member {
        var counts: [UInt64: Int] = [:]
        for member in group where member.info.sharesAllBlocks { counts[member.info.cloneID, default: 0] += 1 }
        var eligible = group
        if let best = counts.values.max() {
            eligible = group.filter { $0.info.sharesAllBlocks && counts[$0.info.cloneID] == best }
        }
        return eligible.min { $0.path < $1.path }!
    }

    /// Whether the file at `url` still has the identity and contents key it was hashed with.
    private static func isUnchanged(_ url: URL, since hashed: CloneInfo) throws -> Bool {
        sameContentsKey(try CloneFS.info(at: url), hashed)
    }

    private static func sameContentsKey(_ a: CloneInfo, _ b: CloneInfo) -> Bool {
        a.device == b.device && a.inode == b.inode && a.size == b.size && a.mtimeNanos == b.mtimeNanos
    }
}
