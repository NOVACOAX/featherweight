import Foundation

public struct CacheFolderSetting: Codable, Equatable, Sendable {
    public var relativePath: String
    public var enabled: Bool
    public var isBuiltIn: Bool

    public init(relativePath: String, enabled: Bool, isBuiltIn: Bool) {
        self.relativePath = relativePath
        self.enabled = enabled
        self.isBuiltIn = isBuiltIn
    }
}

public struct Schedule: Codable, Equatable, Sendable {
    public enum Frequency: String, Codable, Sendable {
        case daily, weekly
    }

    public var frequency: Frequency
    /// 1 = Sunday. Ignored for daily schedules.
    public var weekday: Int
    public var hour: Int
    public var minute: Int

    public init(frequency: Frequency, weekday: Int, hour: Int, minute: Int) {
        self.frequency = frequency
        self.weekday = weekday
        self.hour = hour
        self.minute = minute
    }
}

public struct Settings: Codable, Equatable, Sendable {
    public var projectFolders: [String]
    public var cacheFolders: [CacheFolderSetting]
    public var dedupeSchedule: Schedule
    public var cleanSchedule: Schedule
    public var activityWindowHours: Int
    public var notificationsEnabled: Bool
    public var checkForUpdates: Bool
    public var paused: Bool
    public var onboardingComplete: Bool

    public init(
        projectFolders: [String],
        cacheFolders: [CacheFolderSetting],
        dedupeSchedule: Schedule,
        cleanSchedule: Schedule,
        activityWindowHours: Int,
        notificationsEnabled: Bool,
        checkForUpdates: Bool,
        paused: Bool,
        onboardingComplete: Bool
    ) {
        self.projectFolders = projectFolders
        self.cacheFolders = cacheFolders
        self.dedupeSchedule = dedupeSchedule
        self.cleanSchedule = cleanSchedule
        self.activityWindowHours = activityWindowHours
        self.notificationsEnabled = notificationsEnabled
        self.checkForUpdates = checkForUpdates
        self.paused = paused
        self.onboardingComplete = onboardingComplete
    }

    /// Built-in cache folders, in display order. Everything is on except `.output`.
    private static let builtInCacheFolders: [CacheFolderSetting] = [
        ".next", ".nuxt", ".vite", ".turbo", ".parcel-cache", ".cache",
        "node_modules/.cache", "node_modules/.vite", ".output",
    ].map { CacheFolderSetting(relativePath: $0, enabled: $0 != ".output", isBuiltIn: true) }

    public static func defaults(home: URL) -> Settings {
        let developer = home.appendingPathComponent("Developer", isDirectory: true)
        var isDirectory: ObjCBool = false
        let hasDeveloper = FileManager.default.fileExists(atPath: developer.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
        return Settings(
            projectFolders: hasDeveloper ? [developer.path] : [],
            cacheFolders: builtInCacheFolders,
            dedupeSchedule: Schedule(frequency: .daily, weekday: 1, hour: 3, minute: 0),
            cleanSchedule: Schedule(frequency: .weekly, weekday: 1, hour: 3, minute: 0),
            activityWindowHours: 24,
            notificationsEnabled: true,
            checkForUpdates: true,
            paused: false,
            onboardingComplete: false
        )
    }
}
