import Foundation
import Testing

@testable import FeatherweightCore

@Suite struct InstallDebouncerTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func project(_ root: String) -> Project {
        Project(
            root: URL(fileURLWithPath: root, isDirectory: true), parentRoot: nil, packageManager: .npm,
            nodeModules: URL(fileURLWithPath: root + "/node_modules", isDirectory: true))
    }

    private var projects: [Project] { [project("/dev/a"), project("/dev/a/functions"), project("/dev/proj")] }

    @Test func debouncerIgnoresNonNodeModules() {
        var debouncer = InstallDebouncer()
        debouncer.record(path: "/dev/proj/src/a.ts", eventID: 10, at: t0, ignoreAtOrBelow: 0, projects: projects)

        #expect(debouncer.due(now: t0.addingTimeInterval(3600)).isEmpty)
    }

    @Test func debouncerQuietPeriod() {
        var debouncer = InstallDebouncer()
        debouncer.record(
            path: "/dev/proj/node_modules/react/index.js", eventID: 10, at: t0, ignoreAtOrBelow: 0,
            projects: projects)

        #expect(debouncer.due(now: t0.addingTimeInterval(59)).isEmpty)
        #expect(debouncer.due(now: t0.addingTimeInterval(60)) == [URL(fileURLWithPath: "/dev/proj", isDirectory: true)])
        // Due projects are removed once returned.
        #expect(debouncer.due(now: t0.addingTimeInterval(120)).isEmpty)
    }

    @Test func debouncerResetsOnNewEvent() {
        var debouncer = InstallDebouncer()
        let path = "/dev/proj/node_modules/react/index.js"
        debouncer.record(path: path, eventID: 10, at: t0, ignoreAtOrBelow: 0, projects: projects)
        debouncer.record(path: path, eventID: 11, at: t0.addingTimeInterval(30), ignoreAtOrBelow: 0, projects: projects)

        #expect(debouncer.nextDue == t0.addingTimeInterval(90))
        #expect(debouncer.due(now: t0.addingTimeInterval(60)).isEmpty)
        #expect(debouncer.due(now: t0.addingTimeInterval(89)).isEmpty)
        #expect(debouncer.due(now: t0.addingTimeInterval(90)).map(\.path) == ["/dev/proj"])
        #expect(debouncer.nextDue == nil)
    }

    @Test func debouncerIgnoresOwnEvents() {
        var debouncer = InstallDebouncer()
        debouncer.record(
            path: "/dev/proj/node_modules/react/index.js", eventID: 100, at: t0, ignoreAtOrBelow: 150,
            projects: projects)
        debouncer.record(
            path: "/dev/proj/node_modules/react/index.js", eventID: 150, at: t0, ignoreAtOrBelow: 150,
            projects: projects)

        #expect(debouncer.nextDue == nil)
        #expect(debouncer.due(now: t0.addingTimeInterval(60)).isEmpty)
        #expect(debouncer.due(now: .distantFuture).isEmpty)
    }

    @Test func debouncerMapsNestedToInnermostProject() {
        var debouncer = InstallDebouncer()
        debouncer.record(
            path: "/dev/a/functions/node_modules/x", eventID: 10, at: t0, ignoreAtOrBelow: 0,
            projects: projects)

        #expect(debouncer.due(now: t0.addingTimeInterval(60)).map(\.path) == ["/dev/a/functions"])
    }

    @Test func debouncerIgnoresPathsOutsideKnownProjects() {
        var debouncer = InstallDebouncer()
        // A sibling whose name only starts with a project's name, and an unknown project.
        debouncer.record(path: "/dev/proj2/node_modules/x", eventID: 10, at: t0, ignoreAtOrBelow: 0, projects: projects)
        debouncer.record(path: "/dev/other/node_modules/x", eventID: 11, at: t0, ignoreAtOrBelow: 0, projects: projects)

        #expect(debouncer.due(now: t0.addingTimeInterval(60)).isEmpty)
    }

    @Test func debouncerReturnsEveryDueProjectSorted() {
        var debouncer = InstallDebouncer(quietPeriod: 10)
        debouncer.record(path: "/dev/proj/node_modules/x", eventID: 10, at: t0, ignoreAtOrBelow: 0, projects: projects)
        debouncer.record(path: "/dev/a/node_modules/y", eventID: 11, at: t0, ignoreAtOrBelow: 0, projects: projects)
        debouncer.record(
            path: "/dev/a/functions/node_modules/z", eventID: 12, at: t0.addingTimeInterval(5), ignoreAtOrBelow: 0,
            projects: projects)

        #expect(debouncer.due(now: t0.addingTimeInterval(10)).map(\.path) == ["/dev/a", "/dev/proj"])
        #expect(debouncer.due(now: t0.addingTimeInterval(15)).map(\.path) == ["/dev/a/functions"])
    }

    @Test func debouncerIgnoresNodeModulesCacheFolders() {
        var debouncer = InstallDebouncer(excludedRelativePaths: ["node_modules/.cache", "node_modules/.vite"])
        for (offset, path) in [
            "/dev/proj/node_modules/.cache/babel/x.json", "/dev/proj/node_modules/.vite/deps/react.js",
            "/dev/proj/node_modules/.cache", "/dev/a/functions/node_modules/.cache/y",
        ].enumerated() {
            debouncer.record(path: path, eventID: 10 + UInt64(offset), at: t0, ignoreAtOrBelow: 0, projects: projects)
        }
        #expect(debouncer.nextDue == nil)

        // A sibling whose name only starts with an excluded folder's name still counts.
        debouncer.record(path: "/dev/proj/node_modules/.cachex/z", eventID: 20, at: t0, ignoreAtOrBelow: 0, projects: projects)
        #expect(debouncer.due(now: t0.addingTimeInterval(60)).map(\.path) == ["/dev/proj"])
    }

    @Test func excludedPathsComeFromSettings() {
        let folders = [
            CacheFolderSetting(relativePath: ".next", enabled: true, isBuiltIn: true),
            CacheFolderSetting(relativePath: "node_modules/.cache", enabled: true, isBuiltIn: true),
            CacheFolderSetting(relativePath: "node_modules/.astro", enabled: false, isBuiltIn: false),
        ]
        #expect(InstallDebouncer.excludedRelativePaths(cacheFolders: folders)
            == ["node_modules/.astro", "node_modules/.cache", "node_modules/.vite"])
    }

    @Test func debouncerForgetsOtherJobsEventsInItsProjects() throws {
        let tree = try TempTree(["dev/proj/package.json": "{}", "dev/a/package.json": "{}"])
        defer { tree.remove() }
        let mine = [tree.url("dev/proj").path, tree.url("dev/a").path].map {
            Project(
                root: URL(fileURLWithPath: $0, isDirectory: true), parentRoot: nil, packageManager: .npm,
                nodeModules: URL(fileURLWithPath: $0 + "/node_modules", isDirectory: true))
        }
        var debouncer = InstallDebouncer()
        debouncer.record(path: tree.url("dev/proj/node_modules/x").path, eventID: 100, at: t0, ignoreAtOrBelow: 0, projects: mine)
        debouncer.record(path: tree.url("dev/a/node_modules/x").path, eventID: 101, at: t0, ignoreAtOrBelow: 0, projects: mine)

        // A job that covered only "proj" ended with its history event at 120. Its record names the
        // project through a different spelling of the same folder (/var vs /private/var).
        let spelled = tree.url("dev/proj").path.replacingOccurrences(of: "/private/var/", with: "/var/")
        debouncer.forget(atOrBelow: 120, inProjects: [spelled])
        #expect(debouncer.due(now: t0.addingTimeInterval(60)).map(\.lastPathComponent) == ["a"])

        // Entries with a later event survive.
        debouncer.record(path: tree.url("dev/proj/node_modules/y").path, eventID: 130, at: t0, ignoreAtOrBelow: 0, projects: mine)
        debouncer.forget(atOrBelow: 120, inProjects: [tree.url("dev/proj").path])
        #expect(debouncer.due(now: t0.addingTimeInterval(60)).map(\.lastPathComponent) == ["proj"])
    }

    @Test func debouncerDroppedEventsMarkProjectsUnderPath() {
        var debouncer = InstallDebouncer()
        // MustScanSubDirs for a folder holding projects: every project at or under it.
        debouncer.recordDroppedEvents(under: "/dev/a", eventID: 10, at: t0, ignoreAtOrBelow: 0, projects: projects)
        #expect(debouncer.due(now: t0.addingTimeInterval(60)).map(\.path) == ["/dev/a", "/dev/a/functions"])

        // For a folder inside a project's node_modules: that project.
        debouncer.recordDroppedEvents(
            under: "/dev/proj/node_modules/react", eventID: 11, at: t0, ignoreAtOrBelow: 0, projects: projects)
        #expect(debouncer.due(now: t0.addingTimeInterval(60)).map(\.path) == ["/dev/proj"])

        // Global drop: every project. Own events are still ignored.
        debouncer.recordDroppedEvents(under: nil, eventID: 12, at: t0, ignoreAtOrBelow: 12, projects: projects)
        #expect(debouncer.nextDue == nil)
        debouncer.recordDroppedEvents(under: nil, eventID: 13, at: t0, ignoreAtOrBelow: 12, projects: projects)
        #expect(debouncer.due(now: t0.addingTimeInterval(60)).count == 3)
    }

    @Test func ignoreThresholdIsClampedToCurrentEventID() {
        #expect(InstallDebouncer.ignoreThreshold(lastEventIDs: [], currentEventID: 500) == 0)
        #expect(InstallDebouncer.ignoreThreshold(lastEventIDs: [100, 300, 200], currentEventID: 500) == 300)
        // History from another Mac or before an event-database reset must not silence new events.
        #expect(InstallDebouncer.ignoreThreshold(lastEventIDs: [100, 9_000_000], currentEventID: 500) == 500)
    }
}
