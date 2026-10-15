import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate {
    private let notificationDelegate = NotificationDelegate()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Must be set before launch finishes, so taps on notifications that launched the app arrive.
        UNUserNotificationCenter.current().delegate = notificationDelegate
        let model = AppModel.shared
        model.notifications.registerCategories()
        // Re-arm the optional location wake-ups: when iOS relaunched the app for a location
        // event, the event is only delivered after monitoring was started again.
        model.configureLocationWakeUps()
        return true
    }
}

/// Receives notification taps. Kept free of actor isolation because iOS may call it on any thread.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Also show reminders while the app is open.
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        guard let notification = ReminderPayload.notification(from: response.notification.request.content.userInfo) else {
            completionHandler()
            return
        }
        Task { @MainActor in
            await AppModel.shared.handleNotificationResponse(actionIdentifier: action, notification: notification)
            completionHandler()
        }
    }
}
