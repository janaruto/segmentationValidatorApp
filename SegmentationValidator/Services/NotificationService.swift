import Foundation
import UserNotifications

/// Local notifications only: they are scheduled on the phone itself, no push server is involved.
final class NotificationService {
    static let reminderCategory = "MOVEMENT_REMINDER"
    static let staleCategory = "STALE_SEGMENT"
    static let logAction = "LOG_SEGMENT"
    static let endAction = "END_SEGMENT"
    static let snoozeAction = "SNOOZE"
    static let snoozeDelay: TimeInterval = 15 * 60
    static let locationMovingCategory = "LOCATION_MOVING"
    static let locationStationaryCategory = "LOCATION_STATIONARY"
    static let trueAction = "LOCATION_TRUE"
    static let falseAction = "LOCATION_FALSE"
    static let locationThread = "location-questions"

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
        let end = UNNotificationAction(
            identifier: Self.endAction,
            title: String(localized: "End segment"),
            options: [.foreground]
        )
        let movement = UNNotificationCategory(
            identifier: Self.reminderCategory,
            actions: [log, snooze],
            intentIdentifiers: [],
            options: []
        )
        let stale = UNNotificationCategory(
            identifier: Self.staleCategory,
            actions: [end, snooze],
            intentIdentifiers: [],
            options: []
        )
        // Location questions: True and False. "True" on "Moving detected?" opens the app to
        // pick the movement type; "True" on "Stationary?" is applied right away.
        let trueIcon = UNNotificationActionIcon(systemImageName: "checkmark.circle")
        let falseIcon = UNNotificationActionIcon(systemImageName: "xmark.circle")
        let movingTrue = UNNotificationAction(
            identifier: Self.trueAction,
            title: String(localized: "True"),
            options: [.foreground],
            icon: trueIcon
        )
        let stationaryTrue = UNNotificationAction(
            identifier: Self.trueAction,
            title: String(localized: "True"),
            options: [],
            icon: trueIcon
        )
        let answerFalse = UNNotificationAction(
            identifier: Self.falseAction,
            title: String(localized: "False"),
            options: [],
            icon: falseIcon
        )
        let locationMoving = UNNotificationCategory(
            identifier: Self.locationMovingCategory,
            actions: [movingTrue, answerFalse],
            intentIdentifiers: [],
            options: []
        )
        let locationStationary = UNNotificationCategory(
            identifier: Self.locationStationaryCategory,
            actions: [stationaryTrue, answerFalse],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([movement, stale, locationMoving, locationStationary])
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

    /// Asks to end a live segment that was probably forgotten.
    func post(_ stale: StaleSegmentReminder, delay: TimeInterval? = nil) async {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Segment still running")
        content.body = L10n.format(
            "%1$@ is still running, but you seem to have stopped at %2$@. Tap to end it.",
            stale.type.displayName,
            Formatting.time(stale.stoppedAt)
        )
        content.sound = .default
        content.categoryIdentifier = Self.staleCategory
        content.threadIdentifier = "movement-reminders"
        content.userInfo = ReminderPayload.userInfo(for: stale)

        let trigger = delay.map { UNTimeIntervalNotificationTrigger(timeInterval: max(1, $0), repeats: false) }
        let request = UNNotificationRequest(identifier: "stale-\(stale.segmentID.uuidString)", content: content, trigger: trigger)
        try? await center.add(request)
    }

    /// Asks "Moving detected?" or "Stationary?". `running` is the segment running right now.
    func post(_ prompt: LocationPrompt, running: Segment?, stationaryDistance: Int, delay: TimeInterval? = nil) async {
        let content = UNMutableNotificationContent()
        content.title = prompt.title
        switch prompt.kind {
        case .moving: content.categoryIdentifier = Self.locationMovingCategory
        case .stationary: content.categoryIdentifier = Self.locationStationaryCategory
        }
        content.body = Self.body(for: prompt, running: running, stationaryDistance: stationaryDistance)
        content.sound = .default
        content.threadIdentifier = Self.locationThread
        content.userInfo = ReminderPayload.userInfo(for: prompt)

        // Only the newest question matters: remove older ones from the notification center.
        let older = await center.deliveredNotifications()
            .filter { $0.request.content.threadIdentifier == Self.locationThread }
            .map(\.request.identifier)
        center.removeDeliveredNotifications(withIdentifiers: older)

        let trigger = delay.map { UNTimeIntervalNotificationTrigger(timeInterval: max(1, $0), repeats: false) }
        let request = UNNotificationRequest(identifier: Self.identifier(for: prompt), content: content, trigger: trigger)
        try? await center.add(request)
    }

    /// Removes an answered question from the notification center.
    func removeDelivered(_ prompt: LocationPrompt) {
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier(for: prompt)])
    }

    static func identifier(for prompt: LocationPrompt) -> String {
        "location-\(prompt.id.uuidString)"
    }

    static func body(for prompt: LocationPrompt, running: Segment?, stationaryDistance: Int) -> String {
        var lines = [prompt.question(stationaryDistance: stationaryDistance)]
        if let running {
            switch prompt.kind {
            case .moving:
                lines.append(L10n.format("Now: %1$@ since %2$@", running.type.displayName, Formatting.time(running.start)))
            case .stationary:
                lines.append(L10n.format(
                    "True ends %1$@ at %2$@ and starts Stationary.",
                    running.type.displayName,
                    Formatting.time(max(prompt.since, running.start))
                ))
            }
        }
        return lines.joined(separator: "\n")
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
