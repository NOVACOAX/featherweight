import AppKit
import FeatherweightCore
import Foundation

enum HelperPaths {
    /// `AppPaths.standard`, unless `FEATHERWEIGHT_STATE_DIR` names a folder to keep all state in
    /// (development and testing only). With that override the "home" is the same folder, so the
    /// default project folder (`~/Developer`) is never picked up by accident.
    static func resolve() -> AppPaths {
        guard let override = ProcessInfo.processInfo.environment["FEATHERWEIGHT_STATE_DIR"],
              !override.isEmpty
        else { return .standard }
        let base = URL(fileURLWithPath: override, isDirectory: true)
        return AppPaths(
            base: base, launchAgentsDir: base.appendingPathComponent("LaunchAgents", isDirectory: true),
            home: base)
    }
}

enum HelperLog {
    static func line(_ text: String) {
        FileHandle.standardError.write(Data("featherweight-helper: \(text)\n".utf8))
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let service = HelperService(paths: HelperPaths.resolve())
service.start()
app.run()
