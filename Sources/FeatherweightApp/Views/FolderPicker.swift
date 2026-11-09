import AppKit
import FeatherweightCore

/// Asking the user for a projects folder, and refusing the ones Featherweight cannot manage.
@MainActor
enum FolderPicker {
    static let filesAndFoldersSettings = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!

    /// Shows the folder panel, then checks the choice. Returns the folder's path with symlinks
    /// resolved, or nil if the user cancelled or the folder cannot be used (in which case they have
    /// been told why).
    static func chooseProjectsFolder(home: URL) async -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose a folder that holds your projects."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        // Judge and save where the folder really is, not the link the user happened to pick.
        let resolved = PhysicalPath.resolve(url.path) ?? url.path
        // Reading a protected folder can wait on a system prompt, so not on the main thread.
        let verdict = await Task.detached {
            FolderPolicy(home: home).evaluate(URL(fileURLWithPath: resolved, isDirectory: true))
        }.value

        switch verdict {
        case .ok:
            return resolved
        case .rejectedSync:
            showSyncRefusal()
        case .needsAccess:
            showAccessInstructions(folder: URL(fileURLWithPath: resolved).lastPathComponent)
        }
        return nil
    }

    private static func showSyncRefusal() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "This folder can't be used"
        alert.informativeText = "Featherweight can't manage folders in iCloud Drive or other synced folders. "
            + "Offloaded files would need downloading and every change would re-sync."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func showAccessInstructions(folder: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Allow access to “\(folder)” first"
        alert.informativeText = "macOS keeps this folder private. In System Settings → Privacy & Security → "
            + "Files and Folders, allow access for both “Featherweight” and “Featherweight Helper”, "
            + "then add the folder again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(filesAndFoldersSettings)
        }
    }
}
