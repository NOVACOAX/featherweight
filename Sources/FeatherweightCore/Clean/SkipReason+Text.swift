import Foundation

extension SkipReason {
    /// The user-facing reason a cache folder was left alone. Used in history and the Preview sheet.
    public func displayText(activityWindowHours: Int) -> String {
        switch self {
        case .recentlyActive:
            activityWindowHours == 1
                ? "Active in the last hour" : "Active in the last \(activityWindowHours) hours"
        case .trackedInGit: "Tracked in git"
        case .notEnabled: "Turned off in Settings"
        case .gitUnavailable: "Git unavailable"
        case .pathChanged: "Changed during cleanup"
        case .containsRepository: "Contains a git repository"
        }
    }
}
