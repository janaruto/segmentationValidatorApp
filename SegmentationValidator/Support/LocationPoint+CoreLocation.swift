import CoreLocation

extension LocationPoint {
    init(_ location: CLLocation, trigger: Trigger) {
        self.init(
            timestamp: location.timestamp,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            accuracy: location.horizontalAccuracy,
            altitude: location.verticalAccuracy >= 0 ? location.altitude : nil,
            speed: location.speed >= 0 ? location.speed : nil,
            trigger: trigger
        )
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Accurate enough to be shown on the map and compared with other points.
    var isAccurate: Bool {
        accuracy >= 0 && accuracy <= LocationPromptEngine.maximumAccuracy
    }
}
