import FeatherweightCore
import Foundation
import os

/// What the first launch tells the user before it changes anything, found with dry runs.
struct FirstLaunchEstimate: Equatable, Sendable {
    var projects: Int
    /// What sharing duplicate files would save.
    var duplicateBytes: Int64
    /// What clearing the chosen cache folders would free.
    var cacheBytes: Int64

    #if DEBUG
    /// How many times `compute` has started (the snapshot mode checks that requests are coalesced).
    static let computeCount = OSAllocatedUnfairLock(initialState: 0)
    #endif

    /// Blocks while it walks the projects, so run it off the main actor. Reads the saved settings.
    /// Duplicates are estimated without reading file contents (see `DuplicateEstimate`).
    static func compute(paths: AppPaths) -> FirstLaunchEstimate {
        #if DEBUG
        computeCount.withLock { $0 += 1 }
        #endif
        let settings = SettingsStore(paths: paths).load()
        let projects = ProjectScanner(excludedDirectoryNames: ProjectScanner.excludedNames(for: settings), home: paths.home)
            .scan(folders: settings.projectFolders.map { URL(fileURLWithPath: $0, isDirectory: true) })
        let duplicates = DuplicateEstimate.bytes(projects: projects)
        let (clean, _) = JobRunner(paths: paths).clean(trigger: .firstLaunch, dryRun: true)
        return FirstLaunchEstimate(
            projects: projects.count, duplicateBytes: duplicates, cacheBytes: clean.bytesFreed)
    }
}
