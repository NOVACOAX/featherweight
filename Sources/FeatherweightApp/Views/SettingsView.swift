import AppKit
import FeatherweightCore
import SwiftUI

/// The Settings window (⌘,).
struct SettingsView: View {
    let model: AppModel

    @State private var selectedFolder: String?
    @State private var choosingFolder = false
    @State private var addingCacheFolder = false

    private static let labelWidth: CGFloat = 190
    private static let activityChoices = [6, 12, 24, 48, 72]

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 20, verticalSpacing: 18) {
            row("Projects folders") { projectFolders }
            row("Cache folders to clear") { cacheFolders }
            row("Share duplicates") {
                HStack(spacing: 6) {
                    Text("After installs, and a full sweep")
                    ScheduleEditor(schedule: scheduleBinding(\.dedupeSchedule), weekdayLabel: "on")
                }
            }
            row("Clear build caches") {
                ScheduleEditor(schedule: scheduleBinding(\.cleanSchedule), weekdayLabel: "on")
            }
            row("Leave projects alone if active within") { activityWindow }
            row("General") { general }
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .frame(width: 780, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { model.reload() }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow(alignment: .top) {
            Text(title)
                .foregroundStyle(.secondary)
                .padding(.top, 3)
                .multilineTextAlignment(.trailing)
                .frame(width: Self.labelWidth, alignment: .trailing)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Projects folders

    private var projectFolders: some View {
        let folders = model.settings.projectFolders
        return VStack(alignment: .leading, spacing: 6) {
            VStack(spacing: 0) {
                if folders.isEmpty {
                    Text("No folders yet. Add the folder where your projects live.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                ForEach(folders, id: \.self) { folder in
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill").foregroundStyle(Theme.amber)
                        Text(OnboardingView.displayPath(folder)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(selectedFolder == folder ? Theme.amber.opacity(0.16) : .clear)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedFolder = folder }
                    .accessibilityAddTraits(selectedFolder == folder ? [.isSelected, .isButton] : .isButton)
                    if folder != folders.last { Divider() }
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 0) {
                Button { addFolder() } label: { Image(systemName: "plus").frame(width: 20, height: 16) }
                    .disabled(choosingFolder)
                    .accessibilityLabel("Add a projects folder")
                Button { removeSelectedFolder() } label: { Image(systemName: "minus").frame(width: 20, height: 16) }
                    .disabled(selectedFolder == nil)
                    .accessibilityLabel("Remove the selected folder")
            }
            .controlSize(.small)
        }
    }

    private func addFolder() {
        choosingFolder = true
        Task {
            defer { choosingFolder = false }
            guard let path = await FolderPicker.chooseProjectsFolder(home: model.paths.home) else { return }
            model.updateSettings { settings in
                let known = settings.projectFolders.map { PhysicalPath.resolve($0) ?? $0 }
                if !known.contains(path) { settings.projectFolders.append(path) }
            }
            selectedFolder = path
        }
    }

    private func removeSelectedFolder() {
        guard let folder = selectedFolder else { return }
        model.updateSettings { $0.projectFolders.removeAll { $0 == folder } }
        selectedFolder = nil
    }

    // MARK: Cache folders

    private var cacheFolders: some View {
        VStack(alignment: .leading, spacing: 0) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(minimum: 130), spacing: 12, alignment: .leading), count: 3),
                alignment: .leading, spacing: 8
            ) {
                ForEach(model.settings.cacheFolders, id: \.relativePath) { folder in
                    HStack(spacing: 4) {
                        Toggle(isOn: cacheBinding(folder.relativePath)) {
                            Text(folder.relativePath).font(.system(size: 12, design: .monospaced))
                        }
                        .toggleStyle(.checkbox)
                        if !folder.isBuiltIn {
                            Button { removeCacheFolder(folder.relativePath) } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove \(folder.relativePath) from the list")
                            .accessibilityLabel("Remove \(folder.relativePath)")
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                Text(".output is off by default because many projects deploy from it.")
                    .foregroundStyle(.secondary)
                Button("Add folder name…") { addingCacheFolder = true }
                    .buttonStyle(.link)
                    .foregroundStyle(Theme.amberText)
                    .popover(isPresented: $addingCacheFolder, arrowEdge: .bottom) {
                        AddCacheFolderForm(existing: model.settings.cacheFolders) { folder in
                            model.updateSettings { $0.cacheFolders.append(folder) }
                            addingCacheFolder = false
                        } onCancel: {
                            addingCacheFolder = false
                        }
                    }
            }
            .font(.system(size: 11.5))
            .padding(.top, 10)
            Text("Folders tracked in git are never cleared.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }

    private func cacheBinding(_ path: String) -> Binding<Bool> {
        Binding(
            get: { model.settings.cacheFolders.first { $0.relativePath == path }?.enabled ?? false },
            set: { enabled in
                model.updateSettings { settings in
                    if let index = settings.cacheFolders.firstIndex(where: { $0.relativePath == path }) {
                        settings.cacheFolders[index].enabled = enabled
                    }
                }
            })
    }

    private func removeCacheFolder(_ path: String) {
        model.updateSettings { settings in
            settings.cacheFolders.removeAll { $0.relativePath == path && !$0.isBuiltIn }
        }
    }

    // MARK: Schedules and activity window

    private func scheduleBinding(_ keyPath: WritableKeyPath<FeatherweightCore.Settings, Schedule>) -> Binding<Schedule> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { schedule in model.updateSettings { $0[keyPath: keyPath] = schedule } })
    }

    private var activityWindow: some View {
        let current = model.settings.activityWindowHours
        let choices = Self.activityChoices.contains(current) ? Self.activityChoices : (Self.activityChoices + [current]).sorted()
        return Picker("Activity window", selection: Binding(
            get: { current },
            set: { hours in model.updateSettings { $0.activityWindowHours = hours } })
        ) {
            ForEach(choices, id: \.self) { Text("\($0) hours").tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }

    // MARK: General

    private var general: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Run in background when I log in", isOn: Binding(
                get: { model.launchAgentInstalled },
                set: { enabled in Task { await model.setLaunchAtLogin(enabled) } }))
                .disabled(model.changingLaunchAgent)
            Toggle("Show notifications", isOn: Binding(
                get: { model.settings.notificationsEnabled },
                set: { value in model.updateSettings { $0.notificationsEnabled = value } }))
            Toggle("Check GitHub for new versions", isOn: Binding(
                get: { model.settings.checkForUpdates },
                set: { value in model.updateSettings { $0.checkForUpdates = value } }))
            Toggle(isOn: Binding(
                get: { model.cliCommandInstalled },
                set: { enabled in Task { await model.setCLICommand(enabled) } })
            ) {
                Text("Install the \(Text("featherweight").font(.system(size: 12, design: .monospaced))) terminal command")
            }
            .disabled(model.changingCLICommand)
            if let line = model.cliPathSuggestion {
                PathSuggestion(line: line)
            }
        }
        .toggleStyle(.checkbox)
    }
}

/// Frequency, weekday and time of a job, for example "Weekly on Sunday at 3:00 AM".
private struct ScheduleEditor: View {
    @Binding var schedule: Schedule
    let weekdayLabel: String

    var body: some View {
        HStack(spacing: 6) {
            Picker("Frequency", selection: $schedule.frequency) {
                Text("Daily").tag(Schedule.Frequency.daily)
                Text("Weekly").tag(Schedule.Frequency.weekly)
            }
            .labelsHidden()
            .fixedSize()
            if schedule.frequency == .weekly {
                Text(weekdayLabel)
                Picker("Weekday", selection: $schedule.weekday) {
                    ForEach(Array(Calendar.current.weekdaySymbols.enumerated()), id: \.offset) { index, name in
                        Text(name).tag(index + 1)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            Text("at")
            DatePicker("Time", selection: time, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .datePickerStyle(.field)
                .fixedSize()
        }
    }

    private var time: Binding<Date> {
        Binding(
            get: { Calendar.current.date(from: DateComponents(hour: schedule.hour, minute: schedule.minute)) ?? Date() },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                schedule.hour = parts.hour ?? schedule.hour
                schedule.minute = parts.minute ?? schedule.minute
            })
    }
}

/// Shown when no folder on PATH could take the terminal command: the line to add by hand.
private struct PathSuggestion: View {
    let line: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("None of the folders Featherweight can use is on your PATH. Add this line to your shell's startup file (for example ~/.zshrc), make sure ~/.local/bin exists, then turn this on again.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(line)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(line, forType: .string)
                }
                .controlSize(.small)
            }
        }
        .padding(.top, 4)
    }
}

/// The "Add folder name…" popover: a relative path inside each project, checked before it is added.
private struct AddCacheFolderForm: View {
    let existing: [CacheFolderSetting]
    let onAdd: (CacheFolderSetting) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add a cache folder").font(.system(size: 13, weight: .semibold))
            Text("A folder inside each project, like .astro or node_modules/.parcel-cache.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            TextField("Folder name", text: $name)
                .font(.system(size: 12, design: .monospaced))
                .onSubmit(add)
                .onChange(of: name) { problem = nil }
            if let problem {
                Text(problem)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Add", action: add).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func add() {
        do {
            onAdd(try CacheFolderSetting.custom(named: name, existing: existing))
        } catch {
            problem = error.localizedDescription
        }
    }
}
