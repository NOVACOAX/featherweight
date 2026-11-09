import FeatherweightCore
import SwiftUI

struct ProjectsView: View {
    let model: AppModel
    @State private var filter = ManagerFilter.all
    @State private var search = ""
    @State private var selection: String?

    init(model: AppModel, initialSelection: String? = nil) {
        self.model = model
        _selection = State(initialValue: initialSelection)
    }

    var body: some View {
        let rows = ProjectRows.arrange(model.projects, filter: filter, search: search)
        let selected = rows.first { $0.id == selection }?.project

        VStack(spacing: 0) {
            if model.projects.isEmpty {
                ContentUnavailableView(
                    "No projects yet", systemImage: "folder",
                    description: Text("Featherweight lists every folder with a node_modules inside the projects folders you choose."))
            } else if rows.isEmpty {
                ContentUnavailableView.search
            } else {
                table(rows)
            }
            if let selected {
                ProjectInspector(project: selected, model: model)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
            }
        }
        .navigationTitle("Projects")
        .searchable(text: $search, prompt: "Search projects")
        .toolbar {
            ToolbarItem {
                Picker("Package manager", selection: $filter) {
                    ForEach(ManagerFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Show only projects that use one package manager")
            }
        }
    }

    private func table(_ rows: [ProjectRow]) -> some View {
        Table(rows, selection: $selection) {
            TableColumn("Project") { row in
                Text(row.title)
                    .fontWeight(row.depth == 0 ? .semibold : .regular)
                    .foregroundStyle(row.depth == 0 ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, CGFloat(min(row.depth, 4)) * 18)
            }
            .width(min: 100, ideal: 100)

            TableColumn("Manager") { row in
                PackageManagerBadge(manager: row.project.packageManager)
            }
            .width(min: 48, ideal: 48, max: 56)

            TableColumn("node_modules") { row in
                Text(ByteFormat.string(row.project.nodeModulesBytes)).monospacedDigit()
            }
            .width(min: 74, ideal: 74, max: 84)
            .alignment(.trailing)

            TableColumn("Shared") { row in
                if row.project.packageManager == .pnpm {
                    Text("via pnpm").foregroundStyle(.secondary)
                } else {
                    Text(ByteFormat.string(row.project.sharedBytes)).monospacedDigit()
                }
            }
            .width(min: 56, ideal: 56, max: 64)
            .alignment(.trailing)

            TableColumn("Caches") { row in
                Text(ByteFormat.string(row.project.cacheBytes)).monospacedDigit()
            }
            .width(min: 52, ideal: 52, max: 62)
            .alignment(.trailing)

            TableColumn("Last active") { row in
                Text(row.project.lastActive.map { DateText.ago($0) } ?? "–").foregroundStyle(.secondary)
            }
            .width(min: 84, ideal: 84, max: 96)

            TableColumn("Status") { row in
                StatusPill(text: row.project.status, tone: row.project.statusTone)
            }
            .width(min: 120, ideal: 120, max: 150)
        }
    }
}
