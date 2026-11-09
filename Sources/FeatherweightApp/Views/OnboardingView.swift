import FeatherweightCore
import SwiftUI

/// The first launch screen: pick the projects folder, see what Featherweight can free, then start.
struct OnboardingView: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    @State private var choosingFolder = false

    private var folder: String? { model.settings.projectFolders.first }

    var body: some View {
        VStack(spacing: 0) {
            FeatherweightLogo().frame(width: 88, height: 88)
            Text("Featherweight")
                .font(.system(size: 24, weight: .bold))
                .padding(.top, 14)
            Text("node_modules, but light.")
                .foregroundStyle(.secondary)
                .padding(.top, 4)
                .padding(.bottom, 24)

            folderCard.padding(.bottom, 12)
            foundCard.padding(.bottom, 22)

            HStack(spacing: 8) {
                Button("Customise settings") { openSettings() }
                    .controlSize(.large)
                Button("Start saving space") { Task { await model.startSavingSpace() } }
                    .buttonStyle(AmberButtonStyle())
                    .disabled(!isReady)
            }
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("")
        .safeAreaInset(edge: .top, spacing: 0) {
            if let notice = model.notice {
                NoticeBanner(text: notice) { model.notice = nil }
                    .padding(.horizontal, 26)
                    .padding(.vertical, 10)
            }
        }
        // Whenever the folder or a cache choice changes (here or in Settings), count again. The
        // model runs one count at a time and checks the folders first.
        .task(id: model.settings) { model.refreshFirstLaunchEstimate() }
    }

    private var isReady: Bool {
        if case .ready = model.firstLaunchEstimate { return folder != nil }
        return false
    }

    // MARK: Folder

    private var folderCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.system(size: 20))
                .foregroundStyle(Theme.amber)
            VStack(alignment: .leading, spacing: 1) {
                Text(folder.map(Self.displayPath) ?? "No folder chosen")
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Where your projects live")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(folder == nil ? "Choose…" : "Change…") { chooseFolder() }
                .disabled(choosingFolder)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 440)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }

    private func chooseFolder() {
        choosingFolder = true
        Task {
            defer { choosingFolder = false }
            guard let path = await FolderPicker.chooseProjectsFolder(home: model.paths.home) else { return }
            model.updateSettings { $0.projectFolders = [path] }
        }
    }

    static func displayPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: What was found

    private var foundCard: some View {
        Group {
            switch model.firstLaunchEstimate {
            case .noFolder:
                Text("Choose the folder where your projects live and Featherweight will show what it can free. Nothing is changed until you start.")
            case .scanning:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking through your projects. This can take a minute for a big folder.")
                }
            case .ready(let found):
                Self.summary(found)
            }
        }
        .font(.system(size: 12.5))
        .lineSpacing(3)
        .frame(width: 440 - 28, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.amber.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.amber.opacity(0.3)))
        .accessibilityElement(children: .combine)
    }

    /// "Found 23 projects. About 2.8 GB of duplicate files can be shared, and 12.6 GB of build caches
    /// can be cleared. Nothing has been changed yet."
    static func summary(_ found: FirstLaunchEstimate) -> Text {
        func figure(_ text: String) -> Text { Text(text).bold().foregroundStyle(Theme.amberText) }
        let count = found.projects == 1 ? "1 project" : "\(found.projects) projects"
        return Text("Found ") + figure(count)
            + Text(". About ") + figure(ByteFormat.string(found.duplicateBytes))
            + Text(" of duplicate files can be shared, and ") + figure(ByteFormat.string(found.cacheBytes))
            + Text(" of build caches can be cleared. Nothing has been changed yet.")
    }
}
