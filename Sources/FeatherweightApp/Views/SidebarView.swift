import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case projects = "Projects"
    case activity = "Activity"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .projects: "folder"
        case .activity: "clock"
        }
    }
}

struct SidebarView: View {
    let model: AppModel
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            Label("Overview", systemImage: SidebarItem.overview.symbol).tag(SidebarItem.overview)
            Label("Projects", systemImage: SidebarItem.projects.symbol)
                .badge(model.projects.count)
                .tag(SidebarItem.projects)
            Label("Activity", systemImage: SidebarItem.activity.symbol).tag(SidebarItem.activity)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 8) {
                FeatherweightLogo().frame(width: 22, height: 22)
                Text("Featherweight").font(.system(size: 14, weight: .bold))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { SidebarFooter(model: model) }
        .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
    }
}

private struct SidebarFooter: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(spacing: 6) {
                if model.helperRunning {
                    Circle().fill(Theme.green).frame(width: 7, height: 7)
                    Text("Running in background")
                } else {
                    Circle().strokeBorder(.secondary, lineWidth: 1).frame(width: 7, height: 7)
                    Text("Helper not running")
                    Spacer(minLength: 0)
                    Button("Start") { Task { await model.startHelper() } }
                        .controlSize(.small)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)

            Toggle("Automatic cleanup", isOn: Binding(
                get: { !model.settings.paused },
                set: { model.setPaused(!$0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Theme.amber)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            if model.settings.checkForUpdates, let update = model.availableUpdate {
                Link("Version \(update.version) is available", destination: update.url)
                    .font(.system(size: 12))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }
}
