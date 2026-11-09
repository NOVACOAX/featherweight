#if DEBUG
import AppKit
import FeatherweightCore
import SwiftUI

/// Development aid: with `FEATHERWEIGHT_SNAPSHOT_DIR` set, draws the windows into PNGs in that
/// folder (light and dark) and quits. It draws the app's own views in an off-screen window, so
/// it needs no screen-recording permission. Use it with `FEATHERWEIGHT_STATE_DIR`.
@MainActor
enum SnapshotMode {
    static func runIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let folder = environment["FEATHERWEIGHT_SNAPSHOT_DIR"], !folder.isEmpty else { return }
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

        for item in [SidebarItem.overview, .activity] {
            for dark in [false, true] {
                snapshot(MainWindow(model: model, selection: item).tint(Theme.amber), size: size, dark: dark,
                         to: directory.appendingPathComponent("\(item.rawValue.lowercased())-\(dark ? "dark" : "light").png"))
            }
        }

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
