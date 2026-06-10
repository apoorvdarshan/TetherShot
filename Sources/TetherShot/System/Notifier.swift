import UserNotifications
import Foundation

/// Best-effort banner notifications on capture. Authorization is requested once
/// at launch; if the user declines (or an ad-hoc build can't post), captures
/// still succeed silently — this never blocks the save path.
enum Notifier {
    private static var center: UNUserNotificationCenter? {
        // Guard against environments where no bundle proxy exists (would trap).
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    static func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { Log.shared.log("notifier: auth \(error.localizedDescription)") }
        }
    }

    static func notify(title: String, body: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request) { error in
            if let error { Log.shared.log("notifier: add \(error.localizedDescription)") }
        }
    }
}
