import FeatherweightCore
import Foundation
import os

/// The helper's log, in the unified log (launchd discards a LaunchAgent's stderr). Read it with
/// `log show --predicate 'subsystem == "com.novacoax.featherweight.helper"'`.
enum HelperLog {
    private static let logger = Logger(subsystem: "com.novacoax.featherweight.helper", category: "helper")

    static func line(_ text: String) {
        logger.log("\(text, privacy: .public)")
    }
}

// No AppKit. FSEvents, the timer, the state-directory source and power notifications are all
// scheduled on the main queue, which the main run loop drains on the main thread (`dispatchMain()`
// would park the main thread and run main-queue blocks elsewhere, breaking @MainActor).
let service = HelperService(paths: AppPaths.resolved(environment: ProcessInfo.processInfo.environment))
service.start()
RunLoop.main.run()
