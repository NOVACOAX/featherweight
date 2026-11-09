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

// No AppKit. FSEvents, the timer, the state-directory source and power notifications are all
// scheduled on the main queue, which the main run loop drains on the main thread (`dispatchMain()`
// would park the main thread and run main-queue blocks elsewhere, breaking @MainActor).
let service = HelperService(paths: HelperPaths.resolve())
service.start()
RunLoop.main.run()
