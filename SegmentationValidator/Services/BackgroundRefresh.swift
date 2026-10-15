import BackgroundTasks
import UIKit

/// Background App Refresh: iOS runs the app now and then (when it sees fit) so it can check the
/// motion history and send a reminder. Works without any extra permission.
enum BackgroundRefresh {
    /// Must match `BGTaskSchedulerPermittedIdentifiers` in Info.plist.
    static let taskIdentifier = "com.janaruto.SegmentationValidator.refresh"

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Not available in the simulator or when Background App Refresh is turned off.
        }
    }
}

/// Keeps the app running for a few extra seconds while it handles a background event.
@MainActor
final class BackgroundTime {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    static func run(_ name: String, _ work: @escaping @MainActor () async -> Void) {
        let token = BackgroundTime()
        token.identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            MainActor.assumeIsolated {
                token.end()
            }
        }
        Task { @MainActor in
            await work()
            token.end()
        }
    }

    private func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
