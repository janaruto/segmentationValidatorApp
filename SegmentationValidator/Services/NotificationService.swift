import Foundation
import UserNotifications

/// Local notifications only: they are scheduled on the phone itself, no push server is involved.
final class NotificationService {
    static let reminderCategory = "MOVEMENT_REMINDER"
    static let logAction = "LOG_SEGMENT"
    static let snoozeAction = "SNOOZE"
    static let snoozeDelay: TimeInterval = 15 * 60

    private var center: UNUserNotificationCenter { .current() }

    func registerCategories() {
        let log = UNNotificationAction(
            identifier: Self.logAction,
            title: String(localized: "Log segment"),
            options: [.foreground]
        )
        let snooze = UNNotificationAction(
            identifier: Self.snoozeAction,
            title: String(localized: "Remind me in 15 min"),
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Self.reminderCategory,
            actions: [log, snooze],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func canNotify() async -> Bool {
        switch await authorizationStatus() {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    /// Posts a reminder to log a movement. `previous` is the last logged segment before it.
    func post(_ reminder: Reminder, previous: Segment?, delay: TimeInterval? = nil, identifier: String? = nil) async {
        let content = UNMutableNotificationContent()
        content.title = reminder.end == nil
            ? String(localized: "Movement detected")
            : String(localized: "Movement finished")
        content.body = Self.body(for: reminder, previous: previous)
        content.sound = .default
        content.categoryIdentifier = Self.reminderCategory
        content.threadIdentifier = "movement-reminders"
        content.userInfo = ReminderPayload.userInfo(for: reminder)

        let trigger = delay.map { UNTimeIntervalNotificationTrigger(timeInterval: max(1, $0), repeats: false) }
        // The same movement keeps the same identifier, so an "ended" reminder replaces the "started" one.
        let id = identifier ?? "movement-\(Int(reminder.start.timeIntervalSince1970))"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        try? await center.add(request)
    }

    static func body(for reminder: Reminder, previous: Segment?) -> String {
        let activity = reminder.activity.notificationPhrase
        var lines: [String] = []
        if let end = reminder.end {
            lines.append(L10n.format(
                "%1$@ – %2$@, probably %3$@. Tap to log the segment.",
                Formatting.time(reminder.start), Formatting.time(end), activity
            ))
        } else {
            lines.append(L10n.format(
                "On the move since %1$@, probably %2$@. Tap to log the segment.",
                Formatting.time(reminder.start), activity
            ))
        }
        if let previous {
            if let end = previous.end {
                lines.append(L10n.format("Previous: %1$@ until %2$@", previous.type.displayName, Formatting.time(end)))
            } else {
                lines.append(L10n.format("Previous: %@, still running", previous.type.displayName))
            }
        }
        if reminder.additionalUnlogged > 0 {
            lines.append(L10n.format("+%lld more movements not logged yet", reminder.additionalUnlogged))
        }
        return lines.joined(separator: "\n")
    }
}
