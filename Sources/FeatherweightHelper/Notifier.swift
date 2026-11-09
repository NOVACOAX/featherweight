import FeatherweightCore
import Foundation
import UserNotifications

/// Posts user notifications. Outside an app bundle (`swift run`, a bare `.build` binary)
/// `UNUserNotificationCenter` crashes, so the text is written to stderr instead.
@MainActor
final class Notifier {
    private let center: UNUserNotificationCenter?

    init() {
        center = Bundle.main.bundleIdentifier != nil ? .current() : nil
    }

    func requestAuthorization() {
        guard let center else {
            HelperLog.line("no app bundle; notifications go to stderr")
            return
        }
        center.requestAuthorization(options: [.alert]) { _, error in
            if let error { HelperLog.line("notification authorization failed: \(error.localizedDescription)") }
        }
    }

    func post(_ text: NotificationText) {
        guard let center else {
            HelperLog.line("notification: \(text.title): \(text.body)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request) { error in
            if let error { HelperLog.line("could not post notification: \(error.localizedDescription)") }
        }
    }
}
