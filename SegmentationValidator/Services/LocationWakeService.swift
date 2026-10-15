import CoreLocation
import Foundation

/// Optional helper that lets iOS wake the app when the phone moves a few hundred meters.
///
/// iOS does not let a closed app read the motion sensor continuously. Significant location
/// changes and visits are the battery friendly way to get woken up, so the app can then look
/// at the motion history and send a reminder. Coordinates are never read or stored.
final class LocationWakeService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    /// Called on the main actor whenever iOS delivers a location event.
    var onWake: (@MainActor () -> Void)?
    /// Called on the main actor when the user changes the location permission.
    var onAuthorizationChange: (@MainActor () -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    var authorizationStatus: CLAuthorizationStatus {
        manager.authorizationStatus
    }

    var isSupported: Bool {
        CLLocationManager.significantLocationChangeMonitoringAvailable()
    }

    func requestAlwaysAuthorization() {
        manager.requestAlwaysAuthorization()
    }

    /// Starts or stops the wake-up triggers. Must be called on every app launch while enabled,
    /// otherwise iOS does not deliver the event that relaunched the app.
    func setMonitoring(_ enabled: Bool) {
        guard isSupported else { return }
        if enabled {
            manager.startMonitoringSignificantLocationChanges()
            manager.startMonitoringVisits()
        } else {
            manager.stopMonitoringSignificantLocationChanges()
            manager.stopMonitoringVisits()
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        notifyWake()
    }

    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        notifyWake()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            self?.onAuthorizationChange?()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Nothing to do: the next significant change simply wakes the app again.
    }

    private func notifyWake() {
        Task { @MainActor [weak self] in
            self?.onWake?()
        }
    }
}
