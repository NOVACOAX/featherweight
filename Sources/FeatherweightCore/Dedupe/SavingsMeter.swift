import Foundation

public struct SavingsSnapshot: Codable, Sendable, Equatable {
    /// Bytes not stored twice because files share APFS clone blocks.
    public var sharedBytes: Int64
    /// Shared bytes per project root path.
    public var perProject: [String: Int64]
    public var measuredAt: Date

    public init(sharedBytes: Int64 = 0, perProject: [String: Int64] = [:], measuredAt: Date) {
        self.sharedBytes = sharedBytes
        self.perProject = perProject
        self.measuredAt = measuredAt
    }
}

/// Measures the "Saving now" figure: space saved by clones among projects' `node_modules` files.
public struct SavingsMeter: Sendable {
    public init() {}

    /// Groups the non-empty, single-link files that share all their blocks by (device, cloneID).
    /// A group of n files saves (n − 1) × allocated size; each member but the first in path order
    /// credits its own allocated size to its project. Runs at background QoS with throttled I/O.
    public func measure(projects: [Project], now: Date) -> SavingsSnapshot {
        BackgroundWork.run { Self.tally(projects: projects, now: now) }
    }

    private struct CloneKey: Hashable {
        let device: UInt64
        let cloneID: UInt64
    }

    private struct Clone {
        let path: String
        let project: Int
        let allocatedSize: Int64
    }

    private static func tally(projects: [Project], now: Date) -> SavingsSnapshot {
        var groups: [CloneKey: [Clone]] = [:]
        NodeModulesFiles.forEach(in: projects, onError: { _ in }) { file in
            let info = file.info
            guard NodeModulesFiles.isCandidate(info), info.sharesAllBlocks, info.cloneID != 0 else { return }
            groups[CloneKey(device: info.device, cloneID: info.cloneID), default: []]
                .append(Clone(path: file.url.path, project: file.project, allocatedSize: info.allocatedSize))
        }

        var snapshot = SavingsSnapshot(measuredAt: now)
        for members in groups.values where members.count > 1 {
            for clone in members.sorted(by: { $0.path < $1.path }).dropFirst() {
                snapshot.sharedBytes += clone.allocatedSize
                snapshot.perProject[projects[clone.project].root.path, default: 0] += clone.allocatedSize
            }
        }
        return snapshot
    }
}
