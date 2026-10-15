import Foundation

/// The kinds of movement a segment can have.
///
/// The raw values are the identifiers written to the CSV export, so they must never change.
enum MovementType: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case stationary
    case walking
    case bike
    case busTram = "bus/tram"
    case train
    case car
    case ship
    case cablecar
    case other

    var id: String { rawValue }

    /// Everything except standing still counts as moving.
    var isMoving: Bool { self != .stationary }

    /// The types the phone reports as "automotive". The motion sensor cannot tell them apart.
    static let vehicles: [MovementType] = [.busTram, .train, .car, .ship, .cablecar]

    /// SF Symbol shown for this type.
    var symbolName: String {
        switch self {
        case .stationary: return "figure.stand"
        case .walking: return "figure.walk"
        case .bike: return "bicycle"
        case .busTram: return "tram.fill"
        case .train: return "train.side.front.car"
        case .car: return "car.fill"
        case .ship: return "ferry.fill"
        case .cablecar: return "cablecar.fill"
        case .other: return "ellipsis.circle.fill"
        }
    }

    /// Lenient parser for the CSV import. Accepts the raw values plus common
    /// English and German spellings ("Bus / Tram", "Velo", "zu Fuss", ...).
    init?(csvValue: String) {
        let key = csvValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        if let exact = MovementType(rawValue: key) {
            self = exact
            return
        }
        switch key {
        case "still", "stillstand", "stationär", "stationaer", "stop":
            self = .stationary
        case "walk", "foot", "onfoot", "zufuss", "zufuß", "fuss", "gehen", "running", "run":
            self = .walking
        case "bicycle", "cycling", "cycle", "velo", "fahrrad", "rad", "ebike":
            self = .bike
        case "bus", "tram", "bustram", "öv", "oev":
            self = .busTram
        case "rail", "zug", "bahn":
            self = .train
        case "auto", "automobile", "automotive":
            self = .car
        case "boat", "ferry", "schiff", "boot", "fähre", "faehre":
            self = .ship
        case "seilbahn", "gondola", "gondel":
            self = .cablecar
        case "andere", "sonstiges", "unknown":
            self = .other
        default:
            return nil
        }
    }
}
