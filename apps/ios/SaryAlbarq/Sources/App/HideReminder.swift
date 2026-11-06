import Foundation
import UserNotifications

/// «موقعك مخفي من ٣٠ د، تبي تظهره؟» — one gentle local reminder 30 minutes after «أخفِ موقعي»
/// (works with the screen locked; tapping it opens the trip). Cancelled when shown again.
enum HideReminder {
    static func id(_ outingId: String) -> String { "sary-hidden-\(outingId)" }

    /// When the reminder is due for a hide that started at `since` (nil: none).
    static func dueDate(since: Date?, now: Date = Date()) -> Date? {
        guard let since else { return nil }
        let due = since.addingTimeInterval(HideText.reminderAfterS)
        return due > now ? due : nil
    }

    static func sync(outingId: String, since: Date?, center: UNUserNotificationCenter? = HideReminder.center) {
        guard let center else { return }
        center.removePendingNotificationRequests(withIdentifiers: [id(outingId)])
        guard let due = dueDate(since: since) else { return }
        let c = UNMutableNotificationContent()
        c.title = HideText.reminderTitle
        c.body = HideText.reminderBody
        c.threadIdentifier = "outing-\(outingId)"
        c.sound = nil
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, due.timeIntervalSinceNow), repeats: false)
        center.add(UNNotificationRequest(identifier: id(outingId), content: c, trigger: trigger))
    }

    /// Off in unit tests (no notification permission there).
    static var center: UNUserNotificationCenter? = NSClassFromString("XCTestCase") == nil ? .current() : nil
}
