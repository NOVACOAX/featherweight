import AppKit
import FeatherweightCore
import SwiftUI

@main
struct FeatherweightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Featherweight") {
            MainWindow(model: model)
                .tint(Theme.amber)
        }
        .defaultSize(width: 980, height: 640)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Started from the build folder (`swift run`) there is no bundle to make this a regular app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        #if DEBUG
        SnapshotMode.runIfRequested()
        #endif
    }
}

struct MainWindow: View {
    @Bindable var model: AppModel
    @State private var selection: SidebarItem?

    init(model: AppModel, selection: SidebarItem = .overview) {
        self.model = model
        _selection = State(initialValue: selection)
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model, selection: $selection)
        } detail: {
            switch selection ?? .overview {
            case .overview: OverviewView(model: model)
            case .projects: ProjectsPlaceholder(count: model.projects.count)
            case .activity: ActivityView(model: model)
            }
        }
        .frame(minWidth: 820, minHeight: 540)
        .sheet(item: $model.previewResult) { result in
            PreviewSheet(result: result, activityWindowHours: model.settings.activityWindowHours) {
                model.previewResult = nil
            }
        }
        .task { model.startWatching() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.reload()
        }
    }
}

/// Stands in until the Projects screen exists.
private struct ProjectsPlaceholder: View {
    let count: Int

    var body: some View {
        ContentUnavailableView(
            "Projects", systemImage: "folder",
            description: Text("\(count) \(count == 1 ? "project" : "projects") found."))
            .navigationTitle("Projects")
    }
}
