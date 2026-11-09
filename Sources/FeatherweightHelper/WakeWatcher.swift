import Foundation
import IOKit
import IOKit.pwr_mgt

/// Calls `onWake` on the main thread when the Mac wakes from sleep, using IOKit power
/// notifications (no AppKit, which would add about 30 MB of resident framework pages).
@MainActor
final class WakeWatcher {
    // iokit_common_msg(...) values from IOKit/IOMessage.h; the C macros do not import into Swift.
    private static let canSystemSleep: UInt32 = 0xE000_0270
    private static let systemWillSleep: UInt32 = 0xE000_0280
    private static let systemHasPoweredOn: UInt32 = 0xE000_0300

    private let onWake: @MainActor () -> Void
    private var rootPort: io_connect_t = 0
    private var notifier: io_object_t = 0
    private var port: IONotificationPortRef?

    init(onWake: @escaping @MainActor () -> Void) {
        self.onWake = onWake
    }

    func start() {
        rootPort = IORegisterForSystemPower(
            Unmanaged.passUnretained(self).toOpaque(), &port, Self.callback, &notifier)
        guard rootPort != 0, let port else {
            HelperLog.line("could not register for wake notifications")
            return
        }
        IONotificationPortSetDispatchQueue(port, .main)
    }

    private func handle(_ messageType: UInt32, _ argument: Int) {
        switch messageType {
        case Self.canSystemSleep, Self.systemWillSleep:
            // Every registered client must answer, or sleep is delayed by 30 seconds.
            IOAllowPowerChange(rootPort, argument)
        case Self.systemHasPoweredOn:
            onWake()
        default:
            break
        }
    }

    private static let callback: IOServiceInterestCallback = { refcon, _, messageType, argument in
        guard let refcon else { return }
        let watcher = Unmanaged<WakeWatcher>.fromOpaque(refcon).takeUnretainedValue()
        let argument = Int(bitPattern: argument)
        // The notification port is scheduled on the main queue, so this runs on the main thread.
        MainActor.assumeIsolated { watcher.handle(messageType, argument) }
    }
}
