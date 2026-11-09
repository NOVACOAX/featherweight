import AppKit
import FeatherweightCore
import SwiftUI

@main
struct FeatherweightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Featherweight") {
            RootView(model: model)
                .tint(Theme.amber)
        }
        .defaultSize(width: 980, height: 640)

        Settings {
            SettingsView(model: model)
                .tint(Theme.amber)
        }
    }
}

/// The first launch screen until the user has started, the main window after.
struct RootView: View {
    let model: AppModel

    var body: some View {
        Group {
            if model.settings.onboardingComplete {
                MainWindow(model: model)
            } else {
                OnboardingView(model: model)
                    .frame(minWidth: 560, minHeight: 540)
            }
        }
        .task {
            model.startWatching()
            await model.reinstallHelperIfMoved()
            await model.checkForUpdateIfDue()
        }
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

    private let initialProject: String?

    /// `project` is the row to start with selected (for the snapshot mode).
    init(model: AppModel, selection: SidebarItem = .overview, project: String? = nil) {
        self.model = model
        initialProject = project
        _selection = State(initialValue: selection)
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model, selection: $selection)
        } detail: {
            Group {
                switch selection ?? .overview {
                case .overview: OverviewView(model: model)
                case .projects: ProjectsView(model: model, initialSelection: initialProject)
                case .activity: ActivityView(model: model)
                }
            }
            // A problem shows above whichever screen is open.
            .safeAreaInset(edge: .top, spacing: 0) {
                if let notice = model.notice {
                    NoticeBanner(text: notice) { model.notice = nil }
                        .padding(.horizontal, 26)
                        .padding(.vertical, 10)
                }
            }
        }
        .frame(minWidth: 900, minHeight: 540)
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
