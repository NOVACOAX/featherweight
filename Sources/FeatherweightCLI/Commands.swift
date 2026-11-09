import FeatherweightCore
import Foundation

enum Output {
    static func error(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

enum CLIPaths {
    /// `AppPaths.standard`, unless `FEATHERWEIGHT_STATE_DIR` names a folder to keep all state in
    /// (used for testing the CLI). With that override the "home" is the same folder, so the
    /// default project folder (`~/Developer`) is never picked up by accident.
    static func resolve() -> AppPaths {
        guard let override = ProcessInfo.processInfo.environment["FEATHERWEIGHT_STATE_DIR"],
              !override.isEmpty
        else { return .standard }
        let base = URL(fileURLWithPath: override, isDirectory: true)
        return AppPaths(
            base: base, launchAgentsDir: base.appendingPathComponent("LaunchAgents", isDirectory: true),
            home: base)
    }
}

struct Commands {
    static let usage = """
        Usage: featherweight <command>

        Commands:
          status              Show savings, schedules and whether Featherweight is paused
          dedupe [--dry-run]  Share duplicate files between projects
          clean [--dry-run]   Clear cache folders (.next, .nuxt, ...)
          projects            List projects and their sizes
          pause | resume      Pause or resume scheduled jobs
          log [--limit N]     Show recent runs (default 20)
          uninstall           Remove Featherweight's background helper
          version             Print the version
          help                Print this help
        """

    let paths: AppPaths

    func run(_ command: CLICommand) -> Int32 {
        switch command {
        case .status: return status()
        case .dedupe(let dryRun): return dedupe(dryRun: dryRun)
        case .clean(let dryRun): return clean(dryRun: dryRun)
        case .projects: return projects()
        case .pause: return setPaused(true)
        case .resume: return setPaused(false)
        case .log(let limit): return log(limit: limit)
        case .uninstall:
            print("Featherweight's background helper is not installed.")
            return 0
        case .version:
            print("featherweight \(AppVersion.current)")
            return 0
        case .help:
            print(Self.usage)
            return 0
        }
    }

    // MARK: status

    private func status() -> Int32 {
        let settings = SettingsStore(paths: paths).load()
        let history = HistoryStore(url: paths.history)
        let now = Date()

        print("Saving now: \(ByteFormat.string(readSavings()?.sharedBytes ?? 0))")
        print("Caches cleared this month: "
            + ByteFormat.string(history.cachesClearedThisMonth(now: now, calendar: .current)))
        print("Disk free: \(diskFree())")
        print(jobLine("Dedupe", kind: .dedupe, schedule: settings.dedupeSchedule, settings, history, now))
        print(jobLine("Clean", kind: .clean, schedule: settings.cleanSchedule, settings, history, now))
        print("Paused: \(settings.paused ? "yes" : "no")")
        print("Helper: unknown")
        return 0
    }

    private func jobLine(
        _ title: String, kind: JobKind, schedule: Schedule, _ settings: Settings,
        _ history: HistoryStore, _ now: Date
    ) -> String {
        let last = history.lastRun(of: kind).map { Self.date($0.finishedAt) } ?? "never"
        let next = settings.paused ? "paused" : Self.date(schedule.nextRun(after: now, calendar: .current))
        return "\(title): last run \(last), next run \(next)"
    }

    private func readSavings() -> SavingsSnapshot? {
        guard let data = try? Data(contentsOf: paths.stats) else { return nil }
        return try? JSONDecoder().decode(SavingsSnapshot.self, from: data)
    }

    private func diskFree() -> String {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let values = try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(forKeys: keys),
              let free = values.volumeAvailableCapacityForImportantUsage
        else { return "unknown" }
        let total = values.volumeTotalCapacity.map { " of " + ByteFormat.string(Int64($0)) } ?? ""
        return ByteFormat.string(free) + total
    }

    // MARK: dedupe / clean

    private func dedupe(dryRun: Bool) -> Int32 {
        guard hasProjectFolders() else { return 0 }
        let (report, record) = JobRunner(paths: paths).dedupe(
            trigger: .manualCLI, dryRun: dryRun, onWaiting: Self.announceWaiting)
        if !dryRun, record == nil { return finish(errors: report.errors, didNotRun: true) }
        print("Scanned \(report.filesScanned) files, "
            + "\(dryRun ? "would replace" : "replaced") \(report.filesReplaced) duplicates")
        print(freedLine(report.bytesFreed, dryRun: dryRun))
        return finish(errors: report.errors)
    }

    private func clean(dryRun: Bool) -> Int32 {
        guard hasProjectFolders() else { return 0 }
        let settings = SettingsStore(paths: paths).load()
        let (report, record) = JobRunner(paths: paths).clean(
            trigger: .manualCLI, dryRun: dryRun, onWaiting: Self.announceWaiting)
        if !dryRun, record == nil { return finish(errors: report.errors, didNotRun: true) }
        for candidate in report.cleared {
            print("\(dryRun ? "Would clear" : "Cleared") \(Self.label(candidate)) "
                + "(\(ByteFormat.string(candidate.allocatedBytes)))")
        }
        for candidate in report.skipped {
            let reason = candidate.skip?.displayText(activityWindowHours: settings.activityWindowHours)
                ?? "Skipped"
            print("Skipped \(Self.label(candidate)): \(reason)")
        }
        print(freedLine(report.bytesFreed, dryRun: dryRun))
        return finish(errors: report.errors)
    }

    private static func label(_ candidate: CacheCandidate) -> String {
        URL(fileURLWithPath: candidate.projectRoot).lastPathComponent + "/" + candidate.relativePath
    }

    private func freedLine(_ bytes: Int64, dryRun: Bool) -> String {
        "\(dryRun ? "Would free" : "Freed") \(ByteFormat.string(bytes))"
    }

    private static func announceWaiting() {
        print("Waiting for another Featherweight job to finish…")
        fflush(stdout)
    }

    /// Prints each error to stderr; returns 1 if there were any (or if the job never ran).
    private func finish(errors: [String], didNotRun: Bool = false) -> Int32 {
        errors.forEach(Output.error)
        return errors.isEmpty && !didNotRun ? 0 : 1
    }

    /// False (after printing a hint) when no projects folders are configured.
    private func hasProjectFolders() -> Bool {
        if SettingsStore(paths: paths).load().projectFolders.isEmpty {
            print("No projects folders configured. Open Featherweight to choose one.")
            return false
        }
        return true
    }

    // MARK: projects

    private func projects() -> Int32 {
        guard hasProjectFolders() else { return 0 }
        let summaries = readSummaries() ?? JobRunner(paths: paths).refreshSummaries()
        if summaries.isEmpty {
            print("No projects found.")
            return 0
        }
        let rows = summaries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let width = rows.map(\.name.count).max() ?? 0
        for project in rows {
            print(project.name.padding(toLength: width, withPad: " ", startingAt: 0)
                + "  node_modules \(ByteFormat.string(project.nodeModulesBytes))"
                + ", shared \(ByteFormat.string(project.sharedBytes))"
                + ", caches \(ByteFormat.string(project.cacheBytes))"
                + "  \(project.status)")
        }
        return 0
    }

    private func readSummaries() -> [ProjectSummary]? {
        guard let data = try? Data(contentsOf: paths.projects) else { return nil }
        return try? JSONDecoder().decode([ProjectSummary].self, from: data)
    }

    // MARK: pause / resume

    private func setPaused(_ paused: Bool) -> Int32 {
        let store = SettingsStore(paths: paths)
        var settings = store.load()
        settings.paused = paused
        do {
            try store.save(settings)
        } catch {
            Output.error("Could not save settings: \(error.localizedDescription)")
            return 1
        }
        print(paused ? "Featherweight is paused." : "Featherweight is resumed.")
        return 0
    }

    // MARK: log

    private func log(limit: Int) -> Int32 {
        let records = HistoryStore(url: paths.history).all().prefix(limit)
        if records.isEmpty {
            print("No runs yet.")
            return 0
        }
        for record in records {
            print("\(Self.date(record.finishedAt))  \(record.kind.rawValue)  \(record.trigger.rawValue)  "
                + "Freed \(ByteFormat.string(record.bytesFreed))  \(record.summary)")
            record.errors.forEach { print("    error: \($0)") }
        }
        return 0
    }

    // MARK: formatting

    private static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
