import Foundation

public struct SettingsStore: Sendable {
    private let paths: AppPaths

    public init(paths: AppPaths) {
        self.paths = paths
    }

    /// Returns the saved settings, or the defaults when the file is missing or corrupt.
    public func load() -> Settings {
        guard let data = try? Data(contentsOf: paths.settings),
              let settings = try? JSONDecoder().decode(Settings.self, from: data)
        else {
            return Settings.defaults(home: paths.home)
        }
        return settings
    }

    public func save(_ settings: Settings) throws {
        try paths.ensureExists()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: paths.settings, options: .atomic)
    }
}
