import Foundation

/// Why a project can't be converted to pnpm.
public enum Ineligibility: String, Codable, Sendable {
    case bun, alreadyPnpm, workspaces, recentlyActive, noLockfile

    public func message(windowHours: Int) -> String {
        switch self {
        case .bun: "pnpm can't import bun lockfiles"
        case .alreadyPnpm: "Already uses pnpm"
        case .workspaces: "Monorepos with workspaces aren't supported yet"
        case .recentlyActive:
            windowHours == 1 ? "Active in the last hour" : "Active in the last \(windowHours) hours"
        case .noLockfile: "No lockfile to import"
        }
    }
}

public enum ConversionEligibility {
    /// Nil when `project` can be converted to pnpm.
    public static func check(_ project: Project, activity: ActivityChecker, windowHours: Int) -> Ineligibility? {
        check(project) { activity.isActive(root: project.root, window: TimeInterval(windowHours) * 3600) }
    }

    /// The same check when the caller already knows whether the project was active (the app reads
    /// it from the project summary instead of scanning the project again).
    public static func check(_ project: Project, recentlyActive: Bool) -> Ineligibility? {
        check(project) { recentlyActive }
    }

    private static func check(_ project: Project, isActive: () -> Bool) -> Ineligibility? {
        switch project.packageManager {
        case .bun: return .bun
        case .pnpm: return .alreadyPnpm
        case .none: return .noLockfile
        case .npm, .yarn: break
        }
        if usesWorkspaces(root: project.root) { return .workspaces }
        if isActive() { return .recentlyActive }
        return nil
    }

    private static func usesWorkspaces(root: URL) -> Bool {
        let url = URL(fileURLWithPath: root.path + "/package.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return json["workspaces"] != nil
    }
}
