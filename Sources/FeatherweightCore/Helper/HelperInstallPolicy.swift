import Foundation

/// When the app should (re)install the helper's LaunchAgent, decided without touching launchd.
public enum HelperInstallPolicy {
    public enum Action: Equatable, Sendable {
        /// Write the plist and load it.
        case install
        /// Do nothing.
        case skip
        /// The app is running from a randomised read-only copy (App Translocation); a LaunchAgent
        /// pointing there would break on the next launch. Show `moveNotice` instead.
        case askToMove
    }

    public static let moveNotice = "Move Featherweight to your Applications folder, then open it again."

    /// macOS runs a quarantined app that was never moved from `/private/var/folders/.../AppTranslocation/<id>/d/`.
    public static func isTranslocated(_ helperPath: String) -> Bool {
        helperPath.contains("/AppTranslocation/")
    }

    /// The first-launch "Start saving space" install.
    public static func atFirstInstall(helperPath: String) -> Action {
        isTranslocated(helperPath) ? .askToMove : .install
    }

    /// The check on every launch: reinstall an agent that points somewhere else (the app was
    /// moved). Nothing is done before onboarding finished, or when no agent is installed (the user
    /// may have switched it off), or when it already points at this app's helper.
    public static func atLaunch(onboardingComplete: Bool, installedPath: String?, helperPath: String) -> Action {
        guard onboardingComplete, let installedPath, installedPath != helperPath else { return .skip }
        return isTranslocated(helperPath) ? .askToMove : .install
    }
}
