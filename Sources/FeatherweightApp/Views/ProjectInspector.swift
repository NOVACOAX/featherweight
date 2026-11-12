import AppKit
import FeatherweightCore
import SwiftUI

/// The strip under the table with the selected project's details and actions.
struct ProjectInspector: View {
    let project: ProjectSummary
    let model: AppModel

    var body: some View {
        Card {
            HStack(spacing: 16) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.amber)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name).font(.system(size: 14, weight: .bold))
                    Group {
                        Text((project.id as NSString).abbreviatingWithTildeInPath)
                            .truncationMode(.middle)
                            .help(project.id)
                        if let gitLine { Text(gitLine).truncationMode(.tail) }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
                }
                Spacer(minLength: 12)
                actions
            }
        }
    }

    /// "git: main · github.com/NOVACOAX/linkbreeze", or nil when the project is not in a repository.
    private var gitLine: String? {
        var parts: [String] = []
        if let branch = project.gitBranch { parts.append("git: \(branch)") }
        if let remote = project.remoteURL.flatMap(RemoteURL.hostAndPath) { parts.append(remote) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Actions

    private var actions: some View {
        let skipReason = project.skipReason?.displayText(activityWindowHours: model.settings.activityWindowHours)
        let busy = model.runningJob != nil
        return HStack(spacing: 8) {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.id, isDirectory: true)])
            }

            Button("Clear caches") {
                Task { await model.runClean(preview: false, only: [URL(fileURLWithPath: project.id, isDirectory: true)]) }
            }
            .disabled(skipReason != nil || busy)
            .help(skipReason ?? (busy ? "Another job is running" : "Delete this project's build caches"))

            if project.packageManager == .npm || project.packageManager == .yarn {
                let blocker = model.conversionBlocker(for: project)
                Button("Convert to pnpm…") { model.startConversion(of: project) }
                    .buttonStyle(AmberButtonStyle())
                    .disabled(blocker != nil || busy)
                    .help(blocker ?? (busy ? "Another job is running" : "Switch this project to pnpm, with a backup you can revert to"))
            } else if project.packageManager == .pnpm, let original = model.revertTargets[project.id] {
                if model.runningJob == .revert {
                    ProgressView().controlSize(.small)
                }
                Button("Revert to \(original.rawValue)") { confirmingRevert = true }
                    .disabled(busy)
                    .help(busy ? "Another job is running" : "Undo the conversion to pnpm")
                    .confirmationDialog(
                        "Revert \(project.name) to \(original.rawValue)?", isPresented: $confirmingRevert
                    ) {
                        Button("Revert") { Task { await model.revertProject(project) } }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This puts back the files the conversion changed, removes pnpm-lock.yaml and reinstalls node_modules with \(original.rawValue).")
                    }
            }
        }
        .fixedSize()
    }

    @State private var confirmingRevert = false
}
