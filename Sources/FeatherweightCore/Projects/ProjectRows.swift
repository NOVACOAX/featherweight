import Foundation

/// The Projects screen's package manager filter.
public enum ManagerFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All", npm, pnpm, yarn, bun

    public var id: String { rawValue }

    public func includes(_ manager: PackageManager) -> Bool {
        self == .all || manager.rawValue == rawValue
    }
}

/// One line of the Projects table: a project, how deep it is nested, and the name to show for it.
public struct ProjectRow: Identifiable, Sendable {
    public let project: ProjectSummary
    public let depth: Int
    public let title: String

    public var id: String { project.id }

    public init(project: ProjectSummary, depth: Int, title: String) {
        self.project = project
        self.depth = depth
        self.title = title
    }
}

/// Decides which projects the Projects table shows and in what order.
public enum ProjectRows {
    /// Projects that pass the filter and the search, most recently active first. A nested project
    /// follows its parent when the parent is shown too; otherwise it stands alone, named
    /// "parent/functions" so it still says where it lives. Each project appears at most once.
    public static func arrange(_ projects: [ProjectSummary], filter: ManagerFilter, search: String) -> [ProjectRow] {
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
