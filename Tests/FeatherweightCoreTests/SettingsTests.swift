import Foundation
import Testing
@testable import FeatherweightCore

struct SettingsTests {
    private func makeTempPaths() throws -> AppPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("featherweight-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return AppPaths(
            base: root.appendingPathComponent("State", isDirectory: true),
            launchAgentsDir: root.appendingPathComponent("LaunchAgents", isDirectory: true),
            home: root
        )
    }

    @Test func defaultsHaveSpecCacheFolders() throws {
        let paths = try makeTempPaths()
        let settings = Settings.defaults(home: paths.home)
        #expect(settings.cacheFolders.map(\.relativePath) == [
            ".next", ".nuxt", ".vite", ".turbo", ".parcel-cache", ".cache",
            "node_modules/.cache", "node_modules/.vite", ".output",
        ])
        for folder in settings.cacheFolders {
            #expect(folder.enabled == (folder.relativePath != ".output"))
            #expect(folder.isBuiltIn)
        }
    }

    @Test func defaultsSchedules() throws {
        let paths = try makeTempPaths()
        let settings = Settings.defaults(home: paths.home)
        #expect(settings.dedupeSchedule.frequency == .daily)
        #expect(settings.dedupeSchedule.hour == 3)
        #expect(settings.dedupeSchedule.minute == 0)
        #expect(settings.cleanSchedule.frequency == .weekly)
        #expect(settings.cleanSchedule.weekday == 1)
        #expect(settings.cleanSchedule.hour == 3)
        #expect(settings.cleanSchedule.minute == 0)
        #expect(settings.activityWindowHours == 24)
        #expect(settings.notificationsEnabled)
        #expect(settings.checkForUpdates)
        #expect(!settings.paused)
        #expect(!settings.onboardingComplete)
    }

    @Test func projectFoldersDefaultToDeveloperWhenItExists() throws {
        let paths = try makeTempPaths()
        #expect(Settings.defaults(home: paths.home).projectFolders == [])
        let developer = paths.home.appendingPathComponent("Developer", isDirectory: true)
        try FileManager.default.createDirectory(at: developer, withIntermediateDirectories: true)
        #expect(Settings.defaults(home: paths.home).projectFolders == [developer.path])
    }

    @Test func settingsRoundTrip() throws {
        let paths = try makeTempPaths()
        let store = SettingsStore(paths: paths)
        var settings = Settings.defaults(home: paths.home)
        settings.projectFolders = ["/tmp/Lightroom ", "/tmp/MAgPIE Studio"]
        settings.paused = true
        settings.activityWindowHours = 48
        settings.cacheFolders.append(CacheFolderSetting(relativePath: ".custom", enabled: true, isBuiltIn: false))
        try store.save(settings)
        #expect(store.load() == settings)
    }

    @Test func corruptSettingsFallsBackToDefaults() throws {
        let paths = try makeTempPaths()
        try paths.ensureExists()
        try Data("{".utf8).write(to: paths.settings)
        #expect(SettingsStore(paths: paths).load() == Settings.defaults(home: paths.home))
    }

    @Test func missingSettingsFallsBackToDefaults() throws {
        let paths = try makeTempPaths()
        #expect(SettingsStore(paths: paths).load() == Settings.defaults(home: paths.home))
    }

    @Test func pathsUseSpecFileNames() throws {
        let paths = try makeTempPaths()
        #expect(paths.settings.lastPathComponent == "settings.json")
        #expect(paths.history.lastPathComponent == "history.jsonl")
        #expect(paths.stats.lastPathComponent == "stats.json")
        #expect(paths.projects.lastPathComponent == "projects.json")
        #expect(paths.hashCache.lastPathComponent == "hashes.sqlite")
        #expect(paths.jobLock.lastPathComponent == "jobs.lock")
        #expect(paths.helperPID.lastPathComponent == "helper.pid")
        #expect(paths.backups.lastPathComponent == "backups")
        try paths.ensureExists()
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: paths.backups.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test func automaticWorkWaitsForFirstLaunchAndPause() {
        var settings = Settings.defaults(home: FileManager.default.temporaryDirectory)
        #expect(!settings.onboardingComplete)
        #expect(!settings.automaticWorkAllowed)
        settings.onboardingComplete = true
        #expect(settings.automaticWorkAllowed)
        settings.paused = true
        #expect(!settings.automaticWorkAllowed)
    }
}
