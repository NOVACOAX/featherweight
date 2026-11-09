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
}
