import FeatherweightCore
import Foundation

/// What the first launch tells the user before it changes anything, found with dry runs.
struct FirstLaunchEstimate: Equatable, Sendable {
    var projects: Int
    /// What sharing duplicate files would save.
    var duplicateBytes: Int64
    /// What clearing the chosen cache folders would free.
    var cacheBytes: Int64

    /// Blocks while it scans and hashes, so run it off the main actor. Reads the saved settings.
    static func compute(paths: AppPaths) -> FirstLaunchEstimate {
        let settings = SettingsStore(paths: paths).load()
        let projects = ProjectScanner(excludedDirectoryNames: ProjectScanner.excludedNames(for: settings))
            .scan(folders: settings.projectFolders.map { URL(fileURLWithPath: $0, isDirectory: true) })
        let jobs = JobRunner(paths: paths)
        let (dedupe, _) = jobs.dedupe(trigger: .firstLaunch, dryRun: true)
        let (clean, _) = jobs.clean(trigger: .firstLaunch, dryRun: true)
        return FirstLaunchEstimate(
            projects: projects.count, duplicateBytes: dedupe.bytesFreed, cacheBytes: clean.bytesFreed)
    }
}
