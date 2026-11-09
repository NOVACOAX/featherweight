import Foundation
import Testing

@testable import FeatherweightCore

@Suite struct UpdateCheckerTests {
    private static let release = Data("""
        {"tag_name":"v0.2.0","html_url":"https://github.com/NOVACOAX/featherweight/releases/tag/v0.2.0","draft":false}
        """.utf8)

    @Test func latestReleaseURLIsTheGitHubAPI() {
        #expect(UpdateChecker.latestReleaseURL.absoluteString
            == "https://api.github.com/repos/NOVACOAX/featherweight/releases/latest")
    }

    @Test func isNewer() {
        #expect(UpdateChecker.isNewer("v0.2.0", than: "0.1.9"))
        #expect(!UpdateChecker.isNewer("0.1.0", than: "0.1.0"))
        #expect(UpdateChecker.isNewer("0.10.0", than: "0.9.0"))
    }

    @Test func isNewerEdgeCases() {
        #expect(!UpdateChecker.isNewer("0.1.9", than: "v0.2.0"))
        #expect(UpdateChecker.isNewer("1.0", than: "0.9.9"))
        #expect(!UpdateChecker.isNewer("1.0", than: "1.0.0"))
        #expect(UpdateChecker.isNewer("1.0.1", than: "1.0"))
        // A pre-release is older than its release.
        #expect(!UpdateChecker.isNewer("1.0.0-beta.1", than: "1.0.0"))
        #expect(UpdateChecker.isNewer("1.0.0", than: "1.0.0-beta.1"))
        // Not versions at all: never report an update.
        #expect(!UpdateChecker.isNewer("latest", than: "0.1.0"))
        #expect(!UpdateChecker.isNewer("0.2.0", than: "dev"))
        #expect(!UpdateChecker.isNewer("", than: "0.1.0"))
    }

    @Test func checkParsesRelease() async throws {
        let update = try await UpdateChecker().check(current: "0.1.0") { url in
            #expect(url == UpdateChecker.latestReleaseURL)
            return Self.release
        }

        #expect(update == AvailableUpdate(
            version: "0.2.0", url: URL(string: "https://github.com/NOVACOAX/featherweight/releases/tag/v0.2.0")!))
        let same = try await UpdateChecker().check(current: "0.2.0") { _ in Self.release }
        #expect(same == nil)
        let ahead = try await UpdateChecker().check(current: "0.3.0") { _ in Self.release }
        #expect(ahead == nil)
    }

    @Test func checkIgnoresReleasesWithLinksOffGitHub() async throws {
        let data = Data(#"{"tag_name":"v9.0.0","html_url":"https://evil.example/download"}"#.utf8)

        let update = try await UpdateChecker().check(current: "0.1.0") { _ in data }

        #expect(update == nil)
    }

    @Test func checkThrowsOnGarbage() async {
        await #expect(throws: (any Error).self) {
            try await UpdateChecker().check(current: "0.1.0") { _ in Data("not json".utf8) }
        }
        await #expect(throws: (any Error).self) {
            try await UpdateChecker().check(current: "0.1.0") { _ in Data(#"{"tag_name":"v1"}"#.utf8) }
        }
    }

    @Test func checkPropagatesFetchErrors() async {
        struct Offline: Error {}
        await #expect(throws: Offline.self) {
            try await UpdateChecker().check(current: "0.1.0") { _ in throw Offline() }
        }
    }

    @Test func dueOnlyWhenEnabledAndMoreThanADayHasPassed() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func due(_ last: Date?, enabled: Bool = true) -> Bool {
            UpdateChecker.isDue(lastCheck: last, now: now, enabled: enabled)
        }

        #expect(due(nil))
        #expect(due(now.addingTimeInterval(-25 * 3600)))
        #expect(!due(now.addingTimeInterval(-23 * 3600)))
        #expect(!due(now.addingTimeInterval(-24 * 3600)))
        #expect(!due(nil, enabled: false))
        // A clock that went backwards must not stop checks for good.
        #expect(due(now.addingTimeInterval(3 * 86_400)))
    }
}

@Suite struct AppStateTests {
    @Test func stateLivesNextToSettings() {
        let paths = AppPaths(base: URL(fileURLWithPath: "/tmp/fw"), launchAgentsDir: URL(fileURLWithPath: "/tmp/la"),
                             home: URL(fileURLWithPath: "/tmp"))

        #expect(paths.appState.path == "/tmp/fw/state.json")
    }

    @Test func roundTripsAndToleratesMissingOrCorruptFiles() throws {
        let tree = try TempTree()
        defer { tree.remove() }
        let paths = AppPaths(base: tree.url("state"), launchAgentsDir: tree.url("la"), home: tree.root)
        #expect(AppState.load(from: paths) == AppState())

        let state = AppState(
            lastUpdateCheck: Date(timeIntervalSince1970: 1_700_000_000),
            availableUpdate: AvailableUpdate(version: "0.2.0", url: URL(string: "https://github.com/x/y")!))
        try state.save(to: paths)
        #expect(AppState.load(from: paths) == state)

        try Data("{".utf8).write(to: paths.appState)
        #expect(AppState.load(from: paths) == AppState())
    }

    @Test func oldFilesWithoutTheUpdateFieldStillLoad() throws {
        let tree = try TempTree(["state/state.json": #"{"lastUpdateCheck": 700000000}"#])
        defer { tree.remove() }
        let paths = AppPaths(base: tree.url("state"), launchAgentsDir: tree.url("la"), home: tree.root)

        let state = AppState.load(from: paths)

        #expect(state.lastUpdateCheck == Date(timeIntervalSinceReferenceDate: 700_000_000))
        #expect(state.availableUpdate == nil)
    }
}
