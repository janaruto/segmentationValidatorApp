import Foundation

/// What the phone's motion coprocessor (accelerometer based) thinks the user is doing.
enum DetectedActivity: String, Codable, CaseIterable, Sendable {
    case stationary
    case walking
    case running
    case cycling
    case automotive
    case unknown

    var isMoving: Bool {
        switch self {
        case .walking, .running, .cycling, .automotive: return true
        case .stationary, .unknown: return false
        }
    }

    /// The movement type to pre-select, or `nil` when the phone cannot tell
    /// ("automotive" could be a car, bus, tram, train, ...).
    var suggestedMovementType: MovementType? {
        switch self {
        case .stationary: return .stationary
        case .walking, .running: return .walking
        case .cycling: return .bike
        case .automotive, .unknown: return nil
        }
    }
}

enum ActivityConfidence: Int, Codable, Comparable, Sendable {
    case low = 0
    case medium = 1
    case high = 2

    static func < (lhs: ActivityConfidence, rhs: ActivityConfidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One activity update. It is valid from `start` until the next sample.
struct ActivitySample: Equatable, Sendable {
    var start: Date
    var activity: DetectedActivity
    var confidence: ActivityConfidence
}
