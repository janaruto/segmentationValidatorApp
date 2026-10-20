import CoreLocation
import Foundation

/// Takes a location point every few minutes without keeping GPS on all the time.
///
/// Between two points the location manager keeps running at the lowest accuracy: iOS then
/// relies on cell towers only and switches GPS off, which costs very little battery but keeps
/// the app running in the background, so the next point can be taken on time. For each point
/// the accuracy is raised for a few seconds until a good fix arrives, then lowered again.
///
/// All callbacks arrive on the main thread: the manager is created there, and the timers run
/// on the main run loop.
final class LocationTracker: NSObject, CLLocationManagerDelegate {
    struct Fix {
        var location: CLLocation
        var trigger: LocationPoint.Trigger
    }

    /// Called with every measured point.
    var onFix: (@MainActor (Fix) -> Void)?
    /// Called when the user changes the location permission.
    var onAuthorizationChange: (@MainActor () -> Void)?

    /// A fix at least this accurate (meters) ends the measurement right away.
    static let goodAccuracy: CLLocationAccuracy = 20
    /// GPS stays on at most this long per point; then the best fix so far is used.
    static let maximumMeasuringTime: TimeInterval = 20

    private struct Measurement {
        var startedAt: Date
        var trigger: LocationPoint.Trigger
        var best: CLLocation?
        var timeout: Timer
    }

    private let manager = CLLocationManager()
    private(set) var isTracking = false
    private var interval: TimeInterval = 5 * 60
    /// When the last measurement started, successful or not.
    private var lastAttempt: Date?
    private var nextTimer: Timer?
    private var measurement: Measurement?

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .other
        manager.pausesLocationUpdatesAutomatically = false
    }

    var authorizationStatus: CLAuthorizationStatus {
        manager.authorizationStatus
    }

    /// False when the user only allowed the approximate location (useless for distances).
    var hasPreciseLocation: Bool {
        manager.accuracyAuthorization == .fullAccuracy
    }

    var isMeasuring: Bool {
        measurement != nil
    }

    func requestAlwaysAuthorization() {
        manager.requestAlwaysAuthorization()
    }

    private var isAuthorized: Bool {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return true
        default: return false
        }
    }

    /// Starts taking points, or applies a new interval. `lastPoint` is when the last point was taken.
    func start(interval: TimeInterval, lastPoint: Date?) {
        self.interval = max(60, interval)
        if let lastPoint, lastAttempt.map({ $0 < lastPoint }) ?? true {
            lastAttempt = lastPoint
        }
        guard isAuthorized else {
            stop()
            return
        }
        if !isTracking {
            isTracking = true
            // Requires "location" in UIBackgroundModes (Info.plist).
            manager.allowsBackgroundLocationUpdates = true
            if measurement == nil {
                lowerAccuracy()
            }
            manager.startUpdatingLocation()
        }
        scheduleNext()
    }

    func stop() {
        nextTimer?.invalidate()
        nextTimer = nil
        measurement?.timeout.invalidate()
        measurement = nil
        guard isTracking else { return }
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        isTracking = false
    }

    /// Takes a point if the last one is older than the interval (e.g. when the app is opened).
    func measureIfDue(_ trigger: LocationPoint.Trigger) {
        if isTracking && isDue {
            measure(trigger)
        }
    }

    /// Takes a point now.
    func measure(_ trigger: LocationPoint.Trigger) {
        guard isTracking, measurement == nil else { return }
        nextTimer?.invalidate()
        nextTimer = nil
        let now = Date()
        let timeout = Timer(
            timeInterval: Self.maximumMeasuringTime,
            target: self,
            selector: #selector(measurementTimedOut),
            userInfo: nil,
            repeats: false
        )
        RunLoop.main.add(timeout, forMode: .common)
        measurement = Measurement(startedAt: now, trigger: trigger, best: nil, timeout: timeout)
        lastAttempt = now
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = kCLDistanceFilterNone
    }

    private var isDue: Bool {
        guard let lastAttempt else { return true }
        return Date().timeIntervalSince(lastAttempt) >= interval - 5
    }

    private func lowerAccuracy() {
        // Cell towers only: GPS is off, but iOS keeps the app running in the background.
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = CLLocationDistanceMax
    }

    private func scheduleNext() {
        nextTimer?.invalidate()
        nextTimer = nil
        guard isTracking, measurement == nil else { return }
        let due = (lastAttempt ?? .distantPast).addingTimeInterval(interval)
        let timer = Timer(
            fireAt: max(due, Date().addingTimeInterval(1)),
            interval: 0,
            target: self,
            selector: #selector(timerFired),
            userInfo: nil,
            repeats: false
        )
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        nextTimer = timer
    }

    @objc private func timerFired() {
        measure(.interval)
    }

    @objc private func measurementTimedOut() {
        finishMeasurement()
    }

    private func finishMeasurement() {
        guard let finished = measurement else { return }
        finished.timeout.invalidate()
        measurement = nil
        if isTracking {
            lowerAccuracy()
        }
        if let best = finished.best {
            let fix = Fix(location: best, trigger: finished.trigger)
            MainActor.assumeIsolated {
                self.onFix?(fix)
            }
        }
        scheduleNext()
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard var current = measurement else {
            // Between two points only coarse updates arrive. If a point is overdue because
            // iOS paused the app for a while, take it now.
            if isTracking && isDue {
                measure(.interval)
            }
            return
        }
        for location in locations where location.horizontalAccuracy >= 0
            && location.timestamp >= current.startedAt.addingTimeInterval(-10) {
            if let best = current.best, best.horizontalAccuracy <= location.horizontalAccuracy {
                continue
            }
            current.best = location
        }
        measurement = current
        if let best = current.best, best.horizontalAccuracy <= Self.goodAccuracy {
            finishMeasurement()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            self?.onAuthorizationChange?()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Usually temporary (no fix yet). The measurement simply ends with the best fix it got.
    }
}
