import SwiftUI

extension MovementType {
    var displayName: String {
        switch self {
        case .stationary: return String(localized: "Stationary")
        case .walking: return String(localized: "Walking")
        case .bike: return String(localized: "Bike")
        case .busTram: return String(localized: "Bus/Tram")
        case .train: return String(localized: "Train")
        case .car: return String(localized: "Car")
        case .ship: return String(localized: "Ship")
        case .cablecar: return String(localized: "Cable car")
        case .other: return String(localized: "Other")
        }
    }

    var color: Color {
        switch self {
        case .stationary: return .gray
        case .walking: return .green
        case .bike: return .mint
        case .busTram: return .orange
        case .train: return .red
        case .car: return .blue
        case .ship: return .cyan
        case .cablecar: return .purple
        case .other: return .brown
        }
    }
}

extension DetectedActivity {
    var displayName: String {
        switch self {
        case .stationary: return String(localized: "Stationary")
        case .walking: return String(localized: "Walking")
        case .running: return String(localized: "Running")
        case .cycling: return String(localized: "Bike")
        case .automotive: return String(localized: "Vehicle")
        case .unknown: return String(localized: "Unknown")
        }
    }

    /// Used in "On the move since 08:12, probably …".
    var notificationPhrase: String {
        switch self {
        case .walking: return String(localized: "walking")
        case .running: return String(localized: "running")
        case .cycling: return String(localized: "by bike")
        case .automotive: return String(localized: "in a vehicle")
        case .stationary, .unknown: return String(localized: "on the move")
        }
    }

    var symbolName: String {
        switch self {
        case .stationary: return "figure.stand"
        case .walking: return "figure.walk"
        case .running: return "figure.run"
        case .cycling: return "bicycle"
        case .automotive: return "car.fill"
        case .unknown: return "questionmark"
        }
    }

    var color: Color {
        suggestedMovementType?.color ?? .indigo
    }
}

extension Sensitivity {
    var title: String {
        switch self {
        case .low: return String(localized: "Low")
        case .medium: return String(localized: "Medium")
        case .high: return String(localized: "High")
        }
    }

    var explanation: String {
        switch self {
        case .low:
            return String(localized: "Only movements of at least 10 minutes, at most one reminder every 45 minutes.")
        case .medium:
            return String(localized: "Movements of at least 5 minutes, at most one reminder every 20 minutes.")
        case .high:
            return String(localized: "Movements of at least 2 minutes, at most one reminder every 10 minutes.")
        }
    }
}

extension ReminderTiming {
    var title: String {
        switch self {
        case .start: return String(localized: "At the start")
        case .end: return String(localized: "At the end")
        case .both: return String(localized: "Start and end")
        }
    }
}

extension ReminderOutcome {
    var message: String {
        switch self {
        case .disabled: return String(localized: "Reminders are turned off.")
        case .noPermission: return String(localized: "Motion access is missing.")
        case .noMovement: return String(localized: "No movement detected in the last hours.")
        case .alreadyHandled: return String(localized: "Nothing new: all detected movements are logged or were reminded.")
        case .quietHours: return String(localized: "Quiet hours: the reminder is postponed.")
        case .coolingDown: return String(localized: "A reminder was sent recently. The next one follows later.")
        case .sent: return String(localized: "Reminder sent.")
        }
    }
}

extension DraftError {
    var message: String {
        switch self {
        case .missingType: return String(localized: "Choose a movement type.")
        case .endNotAfterStart: return String(localized: "The end must be after the start.")
        case .runningStartsInFuture: return String(localized: "A running segment cannot start in the future.")
        case .anotherSegmentRunning: return String(localized: "Another segment that starts later is still running.")
        }
    }
}

extension Continuity {
    var message: String {
        switch self {
        case .seamless: return String(localized: "Connects seamlessly")
        case .gap(let duration): return L10n.format("Gap of %@", DurationText.short(duration))
        case .overlap(let duration): return L10n.format("Overlaps by %@", DurationText.short(duration))
        case .running: return String(localized: "Still running")
        }
    }

    var isProblem: Bool {
        switch self {
        case .seamless, .running: return false
        case .gap, .overlap: return true
        }
    }
}
