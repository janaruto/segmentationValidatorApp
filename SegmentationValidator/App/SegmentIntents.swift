import AppIntents

/// Movement types for Shortcuts, Siri and the Action Button.
enum MovementTypeOption: String, AppEnum {
    case stationary
    case walking
    case bike
    case busTram
    case train
    case car
    case ship
    case cablecar
    case other

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Movement type"

    static let caseDisplayRepresentations: [MovementTypeOption: DisplayRepresentation] = [
        .stationary: DisplayRepresentation(title: "Stationary", image: .init(systemName: "figure.stand")),
        .walking: DisplayRepresentation(title: "Walking", image: .init(systemName: "figure.walk")),
        .bike: DisplayRepresentation(title: "Bike", image: .init(systemName: "bicycle")),
        .busTram: DisplayRepresentation(title: "Bus/Tram", image: .init(systemName: "tram.fill")),
        .train: DisplayRepresentation(title: "Train", image: .init(systemName: "train.side.front.car")),
        .car: DisplayRepresentation(title: "Car", image: .init(systemName: "car.fill")),
        .ship: DisplayRepresentation(title: "Ship", image: .init(systemName: "ferry.fill")),
        .cablecar: DisplayRepresentation(title: "Cable car", image: .init(systemName: "cablecar.fill")),
        .other: DisplayRepresentation(title: "Other", image: .init(systemName: "ellipsis.circle.fill")),
    ]

    var movementType: MovementType {
        switch self {
        case .stationary: return .stationary
        case .walking: return .walking
        case .bike: return .bike
        case .busTram: return .busTram
        case .train: return .train
        case .car: return .car
        case .ship: return .ship
        case .cablecar: return .cablecar
        case .other: return .other
        }
    }
}

/// Starts a running segment now, like tapping a type in the app.
struct StartSegmentIntent: AppIntent {
    static let title: LocalizedStringResource = "Start segment"
    static let description = IntentDescription("Starts a running segment now and ends the one that was running.")

    @Parameter(title: "Movement type")
    var type: MovementTypeOption

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AppModel.shared
        model.startLive(type.movementType)
        guard let running = model.book.running, running.type == type.movementType else {
            return .result(dialog: "The segment could not be saved. Open the app and try again.")
        }
        return .result(dialog: "Started: \(running.type.displayName)")
    }
}

/// Ends the running segment, like tapping Stop in the app.
struct StopSegmentIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop segment"
    static let description = IntentDescription("Ends the running segment now.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AppModel.shared
        guard let running = model.book.running else {
            return .result(dialog: "No segment is running.")
        }
        model.stopLive()
        return .result(dialog: "Stopped: \(running.type.displayName)")
    }
}

struct SegmentShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartSegmentIntent(),
            phrases: [
                "Start \(\.$type) in \(.applicationName)",
                "Log \(\.$type) with \(.applicationName)",
            ],
            shortTitle: "Start segment",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: StopSegmentIntent(),
            phrases: [
                "Stop segment in \(.applicationName)",
                "Stop logging in \(.applicationName)",
            ],
            shortTitle: "Stop segment",
            systemImageName: "stop.circle"
        )
    }
}
