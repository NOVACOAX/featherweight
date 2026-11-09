import Foundation

public struct AvailableUpdate: Equatable, Codable, Sendable {
    /// The version without a leading "v", for example "0.2.0".
    public let version: String
    /// The release page on GitHub.
    public let url: URL

    public init(version: String, url: URL) {
        self.version = version
        self.url = url
    }
}

/// Looks for a newer release on GitHub. The only network call Featherweight makes: one GET, at
/// most once a day, with nothing about the user or the machine in it.
public struct UpdateChecker: Sendable {
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/NOVACOAX/featherweight/releases/latest")!
    public static let interval: TimeInterval = 24 * 3600

    public init() {}

    /// True when `candidate` is a higher version than `current`, comparing numbers (so 0.10.0 is
    /// newer than 0.9.0) and ignoring a leading "v". A pre-release is older than its release.
    /// Text that is not a version, such as "dev", is never newer and never older.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let new = Version(candidate), let old = Version(current) else { return false }
        let count = max(new.numbers.count, old.numbers.count)
        for index in 0..<count {
            let a = index < new.numbers.count ? new.numbers[index] : 0
            let b = index < old.numbers.count ? old.numbers[index] : 0
            if a != b { return a > b }
        }
        return old.isPrerelease && !new.isPrerelease
    }

    /// Whether a check is due: updates are on, and more than a day has passed since the last one.
    public static func isDue(lastCheck: Date?, now: Date, enabled: Bool) -> Bool {
        guard enabled else { return false }
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed > interval || elapsed < 0
    }

    /// Fetches the latest release with `fetch` and returns it if it is newer than `current`.
    /// Throws if the response is not a release; returns nil when the release page is not on GitHub.
    public func check(
        current: String, fetch: @Sendable (URL) async throws -> Data
    ) async throws -> AvailableUpdate? {
        let release = try JSONDecoder().decode(Release.self, from: try await fetch(Self.latestReleaseURL))
        guard Self.isNewer(release.tag_name, than: current),
              let url = URL(string: release.html_url),
              url.scheme == "https", let host = url.host?.lowercased(),
              host == "github.com" || host == "www.github.com"
        else { return nil }
        var version = release.tag_name.trimmingCharacters(in: .whitespaces)
        if version.hasPrefix("v") || version.hasPrefix("V") { version.removeFirst() }
        return AvailableUpdate(version: version, url: url)
    }

    /// The real fetch: a plain GET with no cookies, credentials or identifiers.
    public static func fetchFromGitHub(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    private struct Release: Decodable {
        let tag_name: String
        let html_url: String
    }

    private struct Version {
        let numbers: [Int]
        let isPrerelease: Bool

        init?(_ text: String) {
            var text = text.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
            if let build = text.firstIndex(of: "+") { text = String(text[..<build]) }
            let parts = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            isPrerelease = parts.count > 1
            let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            guard !numbers.isEmpty, !numbers.contains(nil) else { return nil }
            self.numbers = numbers.compactMap { $0 }
        }
    }
}

/// Things the app remembers between launches that are not settings.
public struct AppState: Codable, Equatable, Sendable {
    public var lastUpdateCheck: Date?
    /// The newer release the last check found, so the link survives a relaunch until the next check.
    public var availableUpdate: AvailableUpdate?

    public init(lastUpdateCheck: Date? = nil, availableUpdate: AvailableUpdate? = nil) {
        self.lastUpdateCheck = lastUpdateCheck
        self.availableUpdate = availableUpdate
    }

    /// The saved state, or an empty one when the file is missing or corrupt.
    public static func load(from paths: AppPaths) -> AppState {
        guard let data = try? Data(contentsOf: paths.appState),
              let state = try? JSONDecoder().decode(AppState.self, from: data)
        else { return AppState() }
        return state
    }

    public func save(to paths: AppPaths) throws {
        try paths.ensureExists()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: paths.appState, options: .atomic)
    }
}
