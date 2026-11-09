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
        if let remote = project.remoteURL.flatMap(RemoteText.hostAndPath) { parts.append(remote) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Actions

    private var actions: some View {
        let skipReason = project.skipReason(activityWindowHours: model.settings.activityWindowHours)
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

            // Converting arrives with the conversion flow; until then the button only says so.
            if project.packageManager == .npm || project.packageManager == .yarn {
                Button("Convert to pnpm…") { model.notice = "Converting to pnpm is coming soon." }
                    .buttonStyle(AmberButtonStyle())
            }
        }
        .fixedSize()
    }
}

/// Turns a git remote into what people recognise, without any credentials.
enum RemoteText {
    /// "https://user:token@github.com/org/repo.git" -> "github.com/org/repo";
    /// "git@github.com:org/repo.git" -> "github.com/org/repo"; a local path stays a path.
    static func hostAndPath(_ remote: String) -> String? {
        var text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let scheme = text.range(of: "://") {
            // scheme://[user[:password]@]host[:port]/path
            let rest = text[scheme.upperBound...]
            let authorityEnd = rest.firstIndex(of: "/") ?? rest.endIndex
            let authority = rest[..<authorityEnd]
            let host = authority.split(separator: "@", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            text = host + rest[authorityEnd...]
        } else if let colon = text.firstIndex(of: ":"), !text[..<colon].contains("/") {
            // scp-style: [user@]host:path
            let host = text[..<colon].split(separator: "@", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            var path = String(text[text.index(after: colon)...])
            if path.hasPrefix("/") { path.removeFirst() }
            text = host + "/" + path
        }

        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix(".git") { text.removeLast(4) }
        return text.isEmpty ? nil : text
    }
}
