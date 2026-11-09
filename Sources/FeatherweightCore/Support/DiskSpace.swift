import Foundation

public struct DiskSpace {
    /// Free and total bytes of the volume holding `url`. "Free" counts space the system would
    /// make available on demand (purgeable caches), which is the figure Finder shows.
    public static func forVolume(containing url: URL) throws -> (free: Int64, total: Int64) {
        let values = try url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
        ])
        guard let free = values.volumeAvailableCapacityForImportantUsage,
              let total = values.volumeTotalCapacity
        else { throw CocoaError(.fileReadUnknown) }
        return (free, Int64(total))
    }
}
