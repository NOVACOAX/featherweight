import FeatherweightCore
import SwiftUI

/// "<name> now uses pnpm": space freed, the changed files with diffs, warnings, and the commit offer.
struct ConversionDoneSheet: View {
    @Bindable var session: ConversionSession
    let result: ConversionResult
    let model: AppModel

    private var working: Bool {
        if case .working = session.commit { return true }
        return false
    }

    private var finished: Bool {
        switch session.commit {
        case .committed, .pushFailed: true
        default: false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Label("\(session.name) now uses pnpm", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.green)
                Text(headline).font(.system(size: 12.5)).foregroundStyle(.secondary)
            }

            Text("Changes").sectionLabel()
            // A scroll view sized to fit would shrink to almost nothing, so only a long list scrolls.
            if result.changes.count > 6 {
                ScrollView { changeList.padding(.trailing, 4) }.frame(height: 200)
            } else {
                changeList
            }

            if !result.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("These still mention \(session.summary.packageManager.rawValue) and weren't changed:",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.orange)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(result.warnings.enumerated()), id: \.offset) { _, warning in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("\(warning.file):\(warning.line)")
                                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                                    Text(warning.text)
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .truncationMode(.middle)
                                }
                                .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 110)
                }
                .padding(10)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            if session.git != nil {
                commitSection
            }

            footer
        }
    }

    /// Each changed file, expandable to its diff.
    private var changeList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(result.changes, id: \.relativePath) { change in
                DisclosureGroup {
                    DiffView(diff: change.diff)
                } label: {
                    HStack(spacing: 6) {
                        Text(symbol(change.kind))
                            .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(color(change.kind))
                            .frame(width: 12)
                        Text(change.relativePath).font(.system(size: 12.5, design: .monospaced))
                    }
                }
            }
        }
    }

    private var headline: String {
        let freed = result.bytesFreed > 0 ? "Freed \(ByteFormat.string(result.bytesFreed))." : "Converted."
        let check = session.runBuildCheck && session.hasBuildScript
            ? "Your project installed and built cleanly." : "Your project installed cleanly."
        return session.git == nil ? "\(freed) \(check)" : "\(freed) \(check) Commit the change?"
    }

    // MARK: Commit

    @ViewBuilder private var commitSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Commit message", text: $session.commitMessage)
                .textFieldStyle(.roundedBorder)
                .disabled(working || finished)
            if let upstream = session.git?.upstream {
                Text(["Pushes to \(upstream)", session.git?.remote].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            switch session.commit {
            case .idle:
                EmptyView()
            case .working(let pushing):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(pushing ? "Committing and pushing…" : "Committing…")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            case .committed(let pushedTo):
                Label(pushedTo.map { "Committed and pushed to \($0)." } ?? "Committed.", systemImage: "checkmark")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.green)
            case .pushFailed(let output):
                Label("Committed, but the push failed. The commit stays on this Mac.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                CommandOutputBox(text: output, height: 90)
            case .failed(let message):
                Label("Nothing was committed.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                CommandOutputBox(text: message, height: 70)
            }
        }
    }

    // MARK: Buttons

    @ViewBuilder private var footer: some View {
        HStack {
            if finished {
                Spacer()
                Button("Done") { model.closeConversion() }
                    .buttonStyle(AmberButtonStyle())
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Revert") { Task { await model.revertConversion(session) } }
                    .disabled(working)
                Spacer()
                Button("Not now") { model.closeConversion() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)
                if session.git != nil {
                    let pushPrimary = session.git?.upstream != nil && result.warnings.isEmpty
                    commitButton(primary: !pushPrimary)
                    if session.git?.upstream != nil {
                        pushButton(primary: pushPrimary)
                    }
                }
            }
        }
    }

    @ViewBuilder private func commitButton(primary: Bool) -> some View {
        let button = Button("Commit") { Task { await model.commitConversion(session, push: false) } }
            .disabled(working)
        if primary {
            button.buttonStyle(AmberButtonStyle()).keyboardShortcut(.defaultAction)
        } else {
            button
        }
    }

    @ViewBuilder private func pushButton(primary: Bool) -> some View {
        let button = Button("Commit & Push") { Task { await model.pushConversion(session) } }
            .disabled(working)
        if primary {
            button.buttonStyle(AmberButtonStyle()).keyboardShortcut(.defaultAction)
        } else {
            button
        }
    }

    private func symbol(_ kind: FileChange.Kind) -> String {
        switch kind {
        case .added: "+"
        case .deleted: "−"
        case .modified: "~"
        }
    }

    private func color(_ kind: FileChange.Kind) -> Color {
        switch kind {
        case .added: Theme.green
        case .deleted: .red
        case .modified: Theme.amberText
        }
    }
}
