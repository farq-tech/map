import Foundation
import UserNotifications

/// Local notifications for the return timer (a fake in tests).
protocol ReminderScheduling: AnyObject {
    /// Drop `ids`, then schedule `reminders` (same ids replace earlier ones).
    func replace(_ reminders: [ReturnTimerLogic.Reminder], removing ids: [String], outingId: String)
    /// Whether iOS will show them (false: the card says «فعّل الإشعارات ليذكّرك»).
    func authorized() async -> Bool
}

final class LocalReminderScheduler: ReminderScheduling {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) { self.center = center }

    func replace(_ reminders: [ReturnTimerLogic.Reminder], removing ids: [String], outingId: String) {
        center.removePendingNotificationRequests(withIdentifiers: ids)
        for r in reminders {
            let c = UNMutableNotificationContent()
            c.title = r.title
            c.body = r.body
            c.sound = .default
            /* The tap opens this outing (AppDelegate reads the thread id). */
            c.threadIdentifier = "outing-\(outingId)"
            c.userInfo = ["outing_id": outingId, "type": "return_timer_reminder"]
            c.interruptionLevel = .timeSensitive
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: r.fireAt)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            center.add(UNNotificationRequest(identifier: r.id, content: c, trigger: trigger))
        }
    }

    func authorized() async -> Bool {
        let s = await center.notificationSettings()
        return s.authorizationStatus == .authorized || s.authorizationStatus == .provisional || s.authorizationStatus == .ephemeral
    }
}
