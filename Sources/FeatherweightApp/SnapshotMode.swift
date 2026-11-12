#if DEBUG
import AppKit
import FeatherweightCore
import SwiftUI

/// Development aid: with `FEATHERWEIGHT_SNAPSHOT_DIR` set, draws the windows into PNGs in that
/// folder (light and dark) and quits. It draws the app's own views in an off-screen window, so
/// it needs no screen-recording permission.
///
/// It refuses to run without `FEATHERWEIGHT_STATE_DIR`, so it can never read or change the real
/// state directory. It also runs real jobs (a dry run of each, then a real dedupe) against that
/// directory's settings; set `FEATHERWEIGHT_SNAPSHOT_ONLY` to a comma-separated list of screens
/// (`overview`, `projects`, `activity`, `settings`, `onboarding`) to draw just those and run no jobs at all.
/// `conversion` and `conversion-failure` (never part of a default run) convert the first npm project
/// in that directory's folders end to end, through the same calls as the sheets' buttons.
@MainActor
enum SnapshotMode {
    static func runIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let folder = environment["FEATHERWEIGHT_SNAPSHOT_DIR"], !folder.isEmpty else { return }
        guard let stateDirectory = environment["FEATHERWEIGHT_STATE_DIR"], !stateDirectory.isEmpty else {
            FileHandle.standardError.write(Data("FEATHERWEIGHT_SNAPSHOT_DIR needs FEATHERWEIGHT_STATE_DIR too: snapshots must not read the real state directory.\n".utf8))
            exit(1)
        }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        // Wait for the normal window to finish opening, then draw on a later run-loop turn.
        DispatchQueue.main.async {
            Task { @MainActor in
                await run(into: directory)
                exit(0)
            }
        }
    }

    private static func run(into directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = AppModel()
        model.startWatching()
        let size = CGSize(width: 980, height: 640)

        let only = ProcessInfo.processInfo.environment["FEATHERWEIGHT_SNAPSHOT_ONLY"]
            .map { Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }) }
        func wanted(_ item: SidebarItem) -> Bool { only?.contains(item.rawValue.lowercased()) ?? true }

        // The Projects screen starts with a skipped project selected, like the mockup.
        let selectedProject = (model.projects.first { $0.status == "Skipped: active" } ?? model.projects.first)?.id

        for item in SidebarItem.allCases where wanted(item) {
            for dark in [false, true] {
                snapshot(MainWindow(model: model, selection: item, project: selectedProject).tint(Theme.amber), size: size, dark: dark,
                         to: directory.appendingPathComponent("\(item.rawValue.lowercased())-\(dark ? "dark" : "light").png"))
            }
        }
        if wanted(.projects) {
            reportProjectFilters(model.projects)
            // The error banner must show on every screen, not only Overview.
            model.notice = "The clean did not run: another Featherweight job was already running."
            snapshot(MainWindow(model: model, selection: .projects, project: selectedProject).tint(Theme.amber), size: size, dark: false,
                     to: directory.appendingPathComponent("projects-notice-light.png"))
            model.notice = nil
        }
        if only?.contains("settings") ?? true {
            // The first pop-up buttons drawn in a process come out empty, so draw light twice.
            for dark in [false, false, true] {
                await snapshotWaiting(SettingsView(model: model).tint(Theme.amber).background(.background), size: nil, dark: dark, seconds: 1,
                         to: directory.appendingPathComponent("settings-\(dark ? "dark" : "light").png"))
            }
            // What the "Add folder name…" popover says about names it refuses.
            for name in ["../escape", ".git", ".next"] {
                do { _ = try CacheFolderSetting.custom(named: name, existing: model.settings.cacheFolders) }
                catch { print("custom cache folder \"\(name)\": \(error.localizedDescription)") }
            }
        }
        if only?.contains("onboarding") ?? true {
            // Many requests in a row (settings changing while a count runs) must not pile up scans.
            let before = FirstLaunchEstimate.computeCount.withLock { $0 }
            for _ in 0..<6 { model.refreshFirstLaunchEstimate() }
            for _ in 0..<100 {
                if case .ready = model.firstLaunchEstimate { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            let counted = FirstLaunchEstimate.computeCount.withLock { $0 } - before
            print("first launch estimate after 6 requests: \(model.firstLaunchEstimate); scans started: \(counted); notice: \(model.notice ?? "none")")
            // A second job started while one runs is refused, with the reason.
            async let running = model.runDedupe(preview: true)
            let refused = await model.runClean(preview: true)
            let other = await running
            print("two jobs at once: clean -> \(refused ?? "started"), dedupe -> \(other ?? "started"); notice: \(model.notice ?? "none")")
            model.previewResult = nil
            model.notice = nil
            for dark in [false, true] {
                await snapshotWaiting(OnboardingView(model: model).tint(Theme.amber).background(.background),
                         size: CGSize(width: 560, height: 560), dark: dark, seconds: 1.5,
                         to: directory.appendingPathComponent("onboarding-\(dark ? "dark" : "light").png"))
            }
        }
        // Never part of a default run: these convert a real project in the state directory's folders.
        if only?.contains("conversion") == true {
            await runConversion(model: model, into: directory)
        }
        if only?.contains("conversion-failure") == true {
            await runFailingConversion(model: model, into: directory)
        }
        if only != nil { return }

        // Real dry runs against whatever the state directory's settings point at.
        await model.runClean(preview: true)
        if let result = model.previewResult {
            snapshot(PreviewSheet(result: result, activityWindowHours: model.settings.activityWindowHours) {}, size: nil, dark: false,
                     to: directory.appendingPathComponent("preview-clean-light.png"))
            snapshot(PreviewSheet(result: result, activityWindowHours: model.settings.activityWindowHours) {}, size: nil, dark: true,
                     to: directory.appendingPathComponent("preview-clean-dark.png"))
        }
        await model.runDedupe(preview: true)
        if let result = model.previewResult {
            snapshot(PreviewSheet(result: result, activityWindowHours: model.settings.activityWindowHours) {}, size: nil, dark: true,
                     to: directory.appendingPathComponent("preview-dedupe-dark.png"))
        }
        model.previewResult = nil

        // A real run must show up without a relaunch: the job reloads the model, and the watcher
        // reloads it when another process (the helper, the CLI) changes the state directory.
        let before = model.history.count
        await model.runDedupe(preview: false)
        print("after Run now: history \(before) -> \(model.history.count), saving now \(model.savings?.sharedBytes ?? -1) bytes, notice: \(model.notice ?? "none")")
        snapshot(MainWindow(model: model).tint(Theme.amber), size: size, dark: true,
                 to: directory.appendingPathComponent("overview-after-run-dark.png"))

        var changed = model.settings
        changed.paused.toggle()
        try? SettingsStore(paths: model.paths).save(changed)   // as another process would
        for _ in 0..<20 where model.settings.paused != changed.paused {
            try? await Task.sleep(for: .milliseconds(100))
        }
        print("watcher saw external settings change: \(model.settings.paused == changed.paused)")
    }

    // MARK: Conversion end to end

    /// Converts the first top-level npm project through the same `AppModel` calls the sheets' buttons
    /// make, drawing each sheet: confirm, progress, done, then Commit & Push (only to a remote that is
    /// a local path, so it can never reach GitHub), then the inspector's Revert.
    private static func runConversion(model: AppModel, into directory: URL) async {
        guard let project = model.projects.first(where: { $0.packageManager == .npm && $0.parentRoot == nil }) else {
            print("conversion: no top-level npm project in the state directory's folders")
            return
        }
        print("conversion: \(project.name), blocker: \(model.conversionBlocker(for: project) ?? "none")")
        snapshot(MainWindow(model: model, selection: .projects, project: project.id).tint(Theme.amber),
                 size: CGSize(width: 980, height: 640), dark: false,
                 to: directory.appendingPathComponent("conversion-inspector-light.png"))
        guard let session = await openConversion(model: model, project: project, into: directory) else { return }

        async let converting: Void = model.convert(session)
        try? await Task.sleep(for: .seconds(3))
        if case .running = session.phase {
            snapshot(ConversionSheet(session: session, model: model).tint(Theme.amber), size: nil, dark: false,
                     to: directory.appendingPathComponent("conversion-progress-light.png"))
        }
        await converting
        guard case .done(let result) = session.phase else {
            if case .failed(let failure) = session.phase {
                print("conversion: failed at \(failure.step), reverted \(failure.reverted)\n$ \(failure.command)\n\(failure.output)")
            }
            return
        }
        print("conversion: freed \(result.bytesFreed) bytes, pnpm \(result.pnpmVersion)")
        for change in result.changes { print("  \(change.kind) \(change.relativePath)") }
        for warning in result.warnings { print("  warning \(warning.file):\(warning.line) \(warning.text)") }
        print("conversion: git \(session.git.map { "\($0.repoRoot.path) upstream \($0.upstream ?? "none") remote \($0.remote ?? "none")" } ?? "none")")
        for dark in [false, true] {
            snapshot(ConversionSheet(session: session, model: model).tint(Theme.amber), size: nil, dark: dark,
                     to: directory.appendingPathComponent("conversion-done-\(dark ? "dark" : "light").png"))
        }

        if let git = session.git, git.upstream != nil {
            let remote = GitClient(runner: ProcessCommandRunner()).remoteURL(git.repoRoot, remote: "origin") ?? ""
            if remote.hasPrefix("/") || remote.hasPrefix("file://") {
                await model.pushConversion(session)
                print("conversion: commit -> \(session.commit)")
                snapshot(ConversionSheet(session: session, model: model).tint(Theme.amber), size: nil, dark: false,
                         to: directory.appendingPathComponent("conversion-pushed-light.png"))
            } else {
                print("conversion: not pushing to a non-local remote")
            }
        }
        model.closeConversion()

        guard let converted = model.projects.first(where: { $0.id == project.id }) else { return }
        print("conversion: now \(converted.packageManager), revert to \(model.revertTargets[converted.id]?.rawValue ?? "none")")
        snapshot(MainWindow(model: model, selection: .projects, project: converted.id).tint(Theme.amber),
                 size: CGSize(width: 980, height: 640), dark: false,
                 to: directory.appendingPathComponent("conversion-revert-inspector-light.png"))
        await model.revertProject(converted)
        let reverted = model.projects.first { $0.id == project.id }
        print("conversion: after revert \(reverted?.packageManager.rawValue ?? "?"), notice: \(model.notice ?? "none")")
        for record in model.history.prefix(2) { print("  history \(record.kind): \(record.summary) \(record.errors)") }
    }

    /// Converts the first top-level npm project and expects a failure (break it first), drawing the
    /// failure sheet.
    private static func runFailingConversion(model: AppModel, into directory: URL) async {
        guard let project = model.projects.first(where: { $0.packageManager == .npm && $0.parentRoot == nil }),
              let session = await openConversion(model: model, project: project, into: nil) else {
            print("conversion-failure: nothing to convert")
            return
        }
        await model.convert(session)
        if case .failed(let failure) = session.phase {
            print("conversion-failure: failed at \(failure.step), reverted \(failure.reverted), command \(failure.command)")
        } else {
            print("conversion-failure: did not fail")
        }
        snapshot(ConversionSheet(session: session, model: model).tint(Theme.amber), size: nil, dark: false,
                 to: directory.appendingPathComponent("conversion-failed-light.png"))
        model.closeConversion()
    }

    /// Starts the flow and waits for the pnpm check; draws the confirm sheet when `directory` is set.
    private static func openConversion(
        model: AppModel, project: ProjectSummary, into directory: URL?
    ) async -> ConversionSession? {
        model.startConversion(of: project)
        guard let session = model.conversion else { return nil }
        for _ in 0..<300 {
            if case .checkingPnpm = session.phase { try? await Task.sleep(for: .milliseconds(100)) } else { break }
        }
        guard case .confirm = session.phase else {
            print("conversion: pnpm check ended in \(session.phase)")
            if let directory {
                snapshot(ConversionSheet(session: session, model: model).tint(Theme.amber), size: nil, dark: false,
                         to: directory.appendingPathComponent("conversion-install-pnpm-light.png"))
            }
            model.closeConversion()
            return nil
        }
        if let directory {
            for dark in [false, true] {
                snapshot(ConversionSheet(session: session, model: model).tint(Theme.amber), size: nil, dark: dark,
                         to: directory.appendingPathComponent("conversion-confirm-\(dark ? "dark" : "light").png"))
            }
        }
        return session
    }

    /// Prints how many rows the Projects table shows for each filter and a few searches.
    private static func reportProjectFilters(_ projects: [ProjectSummary]) {
        let nested = projects.filter { $0.parentRoot != nil }.count
        print("projects: \(projects.count) in projects.json (\(nested) nested)")
        for filter in ManagerFilter.allCases {
            let rows = ProjectRows.arrange(projects, filter: filter, search: "")
            print("filter \(filter.rawValue): \(rows.count) rows, \(rows.filter { $0.depth > 0 }.count) indented")
        }
        for query in ["functions", "MAgPIE", "zzz"] {
            let rows = ProjectRows.arrange(projects, filter: .all, search: query)
            print("search \"\(query)\": \(rows.map(\.title).joined(separator: ", "))")
        }
    }

    /// Draws `view` in an off-screen window. With no `size` the view is drawn at its own size.
    private static func snapshot<V: View>(
        _ view: V, size: CGSize?, dark: Bool, settle: TimeInterval = 0.6, to url: URL
    ) {
        let (window, host) = present(view, size: size, dark: dark)
        // Let SwiftUI finish its layout passes.
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        capture(window, host, to: url)
    }

    /// Like `snapshot`, but waits by suspending, so the view's own `.task` (which needs the main
    /// actor) can run and finish before the picture is taken.
    private static func snapshotWaiting<V: View>(
        _ view: V, size: CGSize?, dark: Bool, seconds: Double, to url: URL
    ) async {
        let (window, host) = present(view, size: size, dark: dark)
        try? await Task.sleep(for: .seconds(seconds))
        capture(window, host, to: url)
    }

    private static func present<V: View>(_ view: V, size: CGSize?, dark: Bool) -> (NSWindow, NSHostingView<V>) {
        let host = NSHostingView(rootView: view)
        let frame = size.map { NSRect(origin: .zero, size: $0) } ?? NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(
            contentRect: frame, styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        NSApp.appearance = window.appearance
        window.contentView = host
        window.setFrame(window.frameRect(forContentRect: frame), display: true)
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    private static func capture<V: View>(_ window: NSWindow, _ host: NSHostingView<V>, to url: URL) {
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.displayIfNeeded()
        host.layoutSubtreeIfNeeded()
        let target = window.contentView?.superview ?? host
        if let bitmap = target.bitmapImageRepForCachingDisplay(in: target.bounds) {
            target.cacheDisplay(in: target.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: url)
            }
        }
        window.orderOut(nil)
    }
}
#endif
