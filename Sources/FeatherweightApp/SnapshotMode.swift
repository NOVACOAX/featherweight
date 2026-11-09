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
/// (`overview`, `projects`, `activity`) to draw just those and run no jobs at all.
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
    private static func snapshot<V: View>(_ view: V, size: CGSize?, dark: Bool, to url: URL) {
        let host = NSHostingView(rootView: view)
        let frame = size.map { NSRect(origin: .zero, size: $0) } ?? NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(
            contentRect: frame, styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.setFrame(window.frameRect(forContentRect: frame), display: true)
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        // Let SwiftUI finish its layout passes.
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        let target = window.contentView?.superview ?? host
        guard let bitmap = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { return }
        target.cacheDisplay(in: target.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
        window.orderOut(nil)
    }
}
#endif
