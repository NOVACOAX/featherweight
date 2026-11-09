import FeatherweightCore
import SwiftUI

/// The toolbar's package manager filter.
enum ManagerFilter: String, CaseIterable, Identifiable {
    case all = "All", npm, pnpm, yarn, bun

    var id: String { rawValue }

    func includes(_ manager: PackageManager) -> Bool {
        self == .all || manager.rawValue == rawValue
    }
}

/// One line of the table: a project, how deep it is nested, and the name to show for it.
struct ProjectRow: Identifiable {
    let project: ProjectSummary
    let depth: Int
    let title: String

    var id: String { project.id }
}

/// Decides which projects the table shows and in what order.
enum ProjectRows {
    /// Projects that pass the filter and the search, most recently active first. A nested project
    /// follows its parent when the parent is shown too; otherwise it stands alone, named
    /// "parent/functions" so it still says where it lives.
    static func arrange(_ projects: [ProjectSummary], filter: ManagerFilter, search: String) -> [ProjectRow] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = projects.filter { project in
            filter.includes(project.packageManager)
                && (query.isEmpty || project.name.localizedCaseInsensitiveContains(query))
        }
        let shownIDs = Set(shown.map(\.id))

        func isBefore(_ a: ProjectSummary, _ b: ProjectSummary) -> Bool {
            switch (a.lastActive, b.lastActive) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }

        var children: [String: [ProjectSummary]] = [:]
        var roots: [ProjectSummary] = []
        for project in shown {
            if let parent = project.parentRoot, shownIDs.contains(parent) {
                children[parent, default: []].append(project)
            } else {
                roots.append(project)
            }
        }
        var rows: [ProjectRow] = []
        var placed = Set<String>()

        func add(_ project: ProjectSummary, depth: Int, title: String) {
            guard placed.insert(project.id).inserted else { return }
            rows.append(ProjectRow(project: project, depth: depth, title: title))
            for child in (children[project.id] ?? []).sorted(by: isBefore) {
                add(child, depth: depth + 1, title: child.name)
            }
        }

        for root in roots.sorted(by: isBefore) {
            let title = root.parentRoot.map { "\(URL(fileURLWithPath: $0).lastPathComponent)/\(root.name)" } ?? root.name
            add(root, depth: 0, title: title)
        }
        return rows
    }
}

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
