import Foundation

/// One location measurement. While location tracking is on, the app takes one every few
/// minutes. Points are stored on the phone only.
struct LocationPoint: Codable, Identifiable, Hashable, Sendable {
    /// Why the point was taken. Exported to the CSV.
    enum Trigger: String, Codable, CaseIterable, Sendable {
        /// The regular measurement every few minutes.
        case interval
        /// Taken when the app was opened and a point was due.
        case appOpened = "app_opened"
        /// iOS woke the app after a larger movement.
        case wakeUp = "wake_up"
        /// "Measure now" in the settings.
        case manual
    }

    var id: UUID
    var timestamp: Date
    var latitude: Double
    var longitude: Double
    /// Radius of uncertainty in meters.
    var accuracy: Double
    /// Meters above sea level, if known.
    var altitude: Double?
    /// Meters per second, if known.
    var speed: Double?
    var trigger: Trigger
    /// Set when this point led to a question ("Moving detected?" or "Stationary?").
    var prompt: LocationPromptKind?
    /// The answer to that question. `nil` while unanswered.
    var answer: Bool?

    init(
        id: UUID = UUID(),
        timestamp: Date,
        latitude: Double,
        longitude: Double,
        accuracy: Double,
        altitude: Double? = nil,
        speed: Double? = nil,
        trigger: Trigger = .interval,
        prompt: LocationPromptKind? = nil,
        answer: Bool? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
        self.altitude = altitude
        self.speed = speed
        self.trigger = trigger
        self.prompt = prompt
        self.answer = answer
    }

    /// Distance to another point in meters.
    func distance(to other: LocationPoint) -> Double {
        GeoMath.distance(latitude, longitude, other.latitude, other.longitude)
    }

    // Lenient decoding, so that files written by older or newer versions still load.
    private enum CodingKeys: String, CodingKey {
        case id, timestamp, latitude, longitude, accuracy, altitude, speed, trigger, prompt, answer
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        latitude = try container.decode(Double.self, forKey: .latitude)
        longitude = try container.decode(Double.self, forKey: .longitude)
        accuracy = (try? container.decodeIfPresent(Double.self, forKey: .accuracy)) ?? -1
        altitude = try? container.decodeIfPresent(Double.self, forKey: .altitude)
        speed = try? container.decodeIfPresent(Double.self, forKey: .speed)
        trigger = (try? container.decodeIfPresent(Trigger.self, forKey: .trigger)) ?? .interval
        prompt = try? container.decodeIfPresent(LocationPromptKind.self, forKey: .prompt)
        answer = try? container.decodeIfPresent(Bool.self, forKey: .answer)
    }
}

/// The two questions the location points can lead to.
enum LocationPromptKind: String, Codable, CaseIterable, Sendable {
    /// "Moving detected?": far away from the previous point while not moving.
    case moving
    /// "Stationary?": hardly moved for one interval while a moving segment runs.
    case stationary
}

enum GeoMath {
    /// Mean earth radius in meters.
    static let earthRadius = 6_371_008.8

    /// Great-circle distance in meters (haversine formula).
    static func distance(_ latitude1: Double, _ longitude1: Double, _ latitude2: Double, _ longitude2: Double) -> Double {
        let radians = Double.pi / 180
        let deltaLatitude = (latitude2 - latitude1) * radians
        let deltaLongitude = (longitude2 - longitude1) * radians
        let a = sin(deltaLatitude / 2) * sin(deltaLatitude / 2)
            + cos(latitude1 * radians) * cos(latitude2 * radians) * sin(deltaLongitude / 2) * sin(deltaLongitude / 2)
        return 2 * earthRadius * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }

    /// Distance travelled along the points, in meters. Steps smaller than the points'
    /// uncertainty are GPS noise (e.g. while sitting at a desk) and do not count.
    static func travelledDistance(along points: [LocationPoint]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { total, pair in
            let step = pair.0.distance(to: pair.1)
            let noise = max(0, pair.0.accuracy) + max(0, pair.1.accuracy)
            return step > noise ? total + step : total
        }
    }
}
