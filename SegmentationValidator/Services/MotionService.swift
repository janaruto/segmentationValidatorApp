import CoreMotion
import Foundation

enum MotionPermission: Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted
    /// The device has no motion coprocessor (e.g. the simulator).
    case unavailable
}

/// Reads movement activity from the motion coprocessor.
///
/// iOS derives this from the accelerometer in a power efficient way and keeps the last
/// seven days, so the app can look back at what happened while it was closed.
final class MotionService {
    private let manager = CMMotionActivityManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "MotionService"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    var isAvailable: Bool {
        CMMotionActivityManager.isActivityAvailable()
    }

    var permission: MotionPermission {
        guard isAvailable else { return .unavailable }
        switch CMMotionActivityManager.authorizationStatus() {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    /// Activity samples between two dates. iOS only keeps the last seven days.
    func samples(from start: Date, to end: Date) async throws -> [ActivitySample] {
        guard isAvailable else { return [] }
        let oldestAvailable = Date().addingTimeInterval(-7 * 24 * 3600 + 5 * 60)
        let from = max(start, oldestAvailable)
        guard from < end else { return [] }
        return try await withCheckedThrowingContinuation { continuation in
            manager.queryActivityStarting(from: from, to: end, to: queue) { activities, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (activities ?? []).map { ActivitySample($0) })
                }
            }
        }
    }

    /// Asking for data triggers the system permission prompt.
    func requestAuthorization() async -> MotionPermission {
        let now = Date()
        _ = try? await samples(from: now.addingTimeInterval(-10 * 60), to: now)
        return permission
    }

    /// Live updates while the app is open.
    func startLiveUpdates(_ handler: @escaping @MainActor (ActivitySample) -> Void) {
        guard isAvailable else { return }
        manager.startActivityUpdates(to: .main) { activity in
            guard let activity else { return }
            let sample = ActivitySample(activity)
            MainActor.assumeIsolated {
                handler(sample)
            }
        }
    }

    func stopLiveUpdates() {
        manager.stopActivityUpdates()
    }
}

extension ActivitySample {
    init(_ activity: CMMotionActivity) {
        let detected: DetectedActivity
        // "Automotive" wins over "stationary": both are set while a car waits at a red light.
        if activity.automotive {
            detected = .automotive
        } else if activity.cycling {
            detected = .cycling
        } else if activity.running {
            detected = .running
        } else if activity.walking {
            detected = .walking
        } else if activity.stationary {
            detected = .stationary
        } else {
            detected = .unknown
        }

        let confidence: ActivityConfidence
        switch activity.confidence {
        case .high: confidence = .high
        case .medium: confidence = .medium
        default: confidence = .low
        }
        self.init(start: activity.startDate, activity: detected, confidence: confidence)
    }
}
