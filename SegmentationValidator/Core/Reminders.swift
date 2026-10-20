import Foundation

/// How eagerly movements are detected. "Medium" is the default and deliberately not too sensitive.
enum Sensitivity: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high

    var parameters: DetectionParameters {
        switch self {
        case .low:
            return DetectionParameters(
                minimumConfidence: .high,
                minimumRunDuration: 3 * 60,
                maximumPause: 5 * 60,
                minimumEpisodeDuration: 10 * 60,
                reminderCooldown: 45 * 60
            )
        case .medium:
            return DetectionParameters(
                minimumConfidence: .medium,
                minimumRunDuration: 2 * 60,
                maximumPause: 4 * 60,
                minimumEpisodeDuration: 5 * 60,
                reminderCooldown: 20 * 60
            )
        case .high:
            return DetectionParameters(
                minimumConfidence: .low,
                minimumRunDuration: 60,
                maximumPause: 3 * 60,
                minimumEpisodeDuration: 2 * 60,
                reminderCooldown: 10 * 60
            )
        }
    }
}

/// When a reminder is sent for a movement.
enum ReminderTiming: String, Codable, CaseIterable, Sendable {
    /// As soon as the movement is detected.
    case start
    /// Once the movement is over.
    case end
    /// Both.
    case both
}

struct DetectionSettings: Codable, Equatable, Sendable {
    var remindersEnabled = true
    var sensitivity: Sensitivity = .medium
    var timing: ReminderTiming = .start
    var quietHoursEnabled = true
    /// Minutes after midnight.
    var quietHoursStart = 22 * 60
    /// Minutes after midnight.
    var quietHoursEnd = 7 * 60
    /// Let iOS wake the app on significant location changes (location is not stored).
    var useLocationWakeUps = false
    var suggestStationary = true

    /// Save a location point every `locationInterval` minutes (on the phone only).
    var locationTracking = false
    /// Minutes between two location points.
    var locationInterval = 5
    /// Ask "Moving detected?" and "Stationary?" based on the location points.
    var locationPrompts = true
    /// "Moving detected?" when farther than this from the previous point (meters).
    var movingDistance = 400
    /// "Stationary?" when closer than this to the previous point (meters).
    var stationaryDistance = 150

    static let locationIntervalChoices = [1, 2, 5, 10, 15, 30]
    static let movingDistanceChoices = [200, 300, 400, 500, 750, 1000]
    static let stationaryDistanceChoices = [50, 100, 150, 200, 300]

    init() {}

    private enum CodingKeys: String, CodingKey {
        case remindersEnabled, sensitivity, timing, quietHoursEnabled, quietHoursStart, quietHoursEnd
        case useLocationWakeUps, suggestStationary
        case locationTracking, locationInterval, locationPrompts, movingDistance, stationaryDistance
    }

    // Lenient decoding: unknown or missing values fall back to the defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = DetectionSettings()
        remindersEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .remindersEnabled)) ?? defaults.remindersEnabled
        sensitivity = (try? container.decodeIfPresent(Sensitivity.self, forKey: .sensitivity)) ?? defaults.sensitivity
        timing = (try? container.decodeIfPresent(ReminderTiming.self, forKey: .timing)) ?? defaults.timing
        quietHoursEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .quietHoursEnabled)) ?? defaults.quietHoursEnabled
        quietHoursStart = (try? container.decodeIfPresent(Int.self, forKey: .quietHoursStart)) ?? defaults.quietHoursStart
        quietHoursEnd = (try? container.decodeIfPresent(Int.self, forKey: .quietHoursEnd)) ?? defaults.quietHoursEnd
        useLocationWakeUps = (try? container.decodeIfPresent(Bool.self, forKey: .useLocationWakeUps)) ?? defaults.useLocationWakeUps
        suggestStationary = (try? container.decodeIfPresent(Bool.self, forKey: .suggestStationary)) ?? defaults.suggestStationary
        locationTracking = (try? container.decodeIfPresent(Bool.self, forKey: .locationTracking)) ?? defaults.locationTracking
        locationPrompts = (try? container.decodeIfPresent(Bool.self, forKey: .locationPrompts)) ?? defaults.locationPrompts
        let interval = (try? container.decodeIfPresent(Int.self, forKey: .locationInterval)) ?? defaults.locationInterval
        locationInterval = min(max(interval, 1), 60)
        let moving = (try? container.decodeIfPresent(Int.self, forKey: .movingDistance)) ?? defaults.movingDistance
        movingDistance = min(max(moving, 50), 10_000)
        let stationary = (try? container.decodeIfPresent(Int.self, forKey: .stationaryDistance)) ?? defaults.stationaryDistance
        stationaryDistance = min(max(stationary, 20), 5_000)
    }
}

/// A reminder to log a detected movement.
struct Reminder: Equatable, Sendable {
    var start: Date
    /// `nil` while the movement is still going on.
    var end: Date?
    var activity: DetectedActivity
    /// Other movements in the last hours that are not logged yet either.
    var additionalUnlogged: Int = 0
}

/// What the reminder logic remembers between checks (stored in UserDefaults).
struct ReminderState: Codable, Equatable, Sendable {
    var lastReminderAt: Date?
    /// Start times of movements a "started" reminder was sent for (or that needed none).
    var startHandled: [Date] = []
    /// Start times of movements an "ended" reminder was sent for (or that needed none).
    var endHandled: [Date] = []
    /// Running segments a "still running?" reminder was sent for.
    var staleHandled: [UUID] = []
    var lastCheckAt: Date?
    var lastOutcome: ReminderOutcome?

    init() {}

    mutating func prune(before cutoff: Date) {
        startHandled.removeAll { $0 < cutoff }
        endHandled.removeAll { $0 < cutoff }
        if staleHandled.count > 50 {
            staleHandled.removeFirst(staleHandled.count - 50)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case lastReminderAt, startHandled, endHandled, staleHandled, lastCheckAt, lastOutcome
    }

    // Lenient decoding, so that state written by another app version never gets lost.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastReminderAt = try? container.decodeIfPresent(Date.self, forKey: .lastReminderAt)
        startHandled = (try? container.decodeIfPresent([Date].self, forKey: .startHandled)) ?? []
        endHandled = (try? container.decodeIfPresent([Date].self, forKey: .endHandled)) ?? []
        staleHandled = (try? container.decodeIfPresent([UUID].self, forKey: .staleHandled)) ?? []
        lastCheckAt = try? container.decodeIfPresent(Date.self, forKey: .lastCheckAt)
        lastOutcome = try? container.decodeIfPresent(ReminderOutcome.self, forKey: .lastOutcome)
    }
}

/// A moving segment is still running although the phone has been lying still for a while.
struct StaleSegmentReminder: Equatable, Sendable {
    var segmentID: UUID
    var type: MovementType
    /// When the phone stopped moving: the suggested end of the segment.
    var stoppedAt: Date
}

enum ReminderOutcome: String, Codable, Sendable {
    case disabled
    case noPermission
    case noMovement
    case alreadyHandled
    case quietHours
    case coolingDown
    case sent
    /// The location questions ("Moving detected?") take over while location points are recorded.
    case locationActive
}

/// Decides whether a reminder notification should be sent right now.
enum ReminderEngine {
    /// Movements older than this are not reminded about any more (they still show up as suggestions).
    static let lookback: TimeInterval = 3 * 3600
    /// Detected start times may shift a little as more sensor data arrives.
    static let matchTolerance: TimeInterval = 5 * 60

    struct Result: Equatable, Sendable {
        var outcome: ReminderOutcome
        var reminder: Reminder?
        var state: ReminderState
    }

    static func evaluate(
        episodes: [MovementEpisode],
        book: SegmentBook,
        state previous: ReminderState,
        settings: DetectionSettings,
        now: Date,
        calendar: Calendar
    ) -> Result {
        var state = previous
        state.prune(before: now.addingTimeInterval(-2 * 86_400))
        state.lastCheckAt = now

        func finish(_ outcome: ReminderOutcome, _ reminder: Reminder? = nil) -> Result {
            state.lastOutcome = outcome
            return Result(outcome: outcome, reminder: reminder, state: state)
        }

        guard settings.remindersEnabled else { return finish(.disabled) }

        let parameters = settings.sensitivity.parameters
        let recent = episodes.filter { episode in
            episode.duration >= parameters.minimumEpisodeDuration
                && (episode.isOngoing || episode.end >= now.addingTimeInterval(-lookback))
        }
        guard !recent.isEmpty else { return finish(.noMovement) }

        // Movements the user already logged never trigger a reminder.
        var unlogged: [MovementEpisode] = []
        for episode in recent {
            if isLogged(episode, in: book, now: now) {
                markHandled(episode, in: &state)
            } else {
                unlogged.append(episode)
            }
        }

        let wantsStart = settings.timing != .end
        let wantsEnd = settings.timing != .start
        let due = unlogged.filter { episode in
            let startDue = wantsStart && !wasHandled(episode, in: state.startHandled, now: now)
            let endDue = wantsEnd && !episode.isOngoing && !wasHandled(episode, in: state.endHandled, now: now)
            return startDue || endDue
        }
        guard let latest = due.max(by: { $0.start < $1.start }) else { return finish(.alreadyHandled) }

        if isQuietTime(now, settings: settings, calendar: calendar) {
            return finish(.quietHours)
        }
        if let last = state.lastReminderAt, now.timeIntervalSince(last) < parameters.reminderCooldown {
            return finish(.coolingDown)
        }

        let reminder = Reminder(
            start: latest.start,
            end: latest.isOngoing ? nil : latest.end,
            activity: latest.dominantActivity,
            additionalUnlogged: due.count - 1
        )
        // One notification covers everything that is due; older movements are summarised in it.
        for episode in due {
            if episode.isOngoing {
                state.startHandled.append(episode.start)
            } else {
                markHandled(episode, in: &state)
            }
        }
        state.lastReminderAt = now
        return finish(.sent, reminder)
    }

    /// How long the phone has to be still before a running moving segment counts as forgotten.
    static func staleThreshold(for parameters: DetectionParameters) -> TimeInterval {
        max(15 * 60, 3 * parameters.maximumPause)
    }

    /// Checks whether a running moving segment (live logging) was probably forgotten:
    /// the motion sensor says the phone has been still since some time after the segment started.
    static func evaluateStale(
        runs: [DetectedRun],
        book: SegmentBook,
        state previous: ReminderState,
        settings: DetectionSettings,
        now: Date,
        calendar: Calendar
    ) -> (reminder: StaleSegmentReminder?, state: ReminderState) {
        var state = previous
        guard settings.remindersEnabled,
              let running = book.running,
              running.type.isMoving,
              !state.staleHandled.contains(running.id),
              let last = runs.last,
              last.isOngoing,
              last.activity == .stationary,
              last.start > running.start,
              now.timeIntervalSince(last.start) >= staleThreshold(for: settings.sensitivity.parameters)
        else {
            return (nil, state)
        }
        if isQuietTime(now, settings: settings, calendar: calendar) {
            return (nil, state)
        }
        if let lastReminder = state.lastReminderAt,
           now.timeIntervalSince(lastReminder) < settings.sensitivity.parameters.reminderCooldown {
            return (nil, state)
        }
        state.staleHandled.append(running.id)
        state.lastReminderAt = now
        return (StaleSegmentReminder(segmentID: running.id, type: running.type, stoppedAt: last.start), state)
    }

    /// True when logged moving segments cover at least half of the movement.
    static func isLogged(_ episode: MovementEpisode, in book: SegmentBook, now: Date) -> Bool {
        let interval = episode.interval
        guard interval.duration > 0 else { return true }
        let moving = book.segments.filter { $0.type.isMoving }.map { $0.interval(now: now) }
        return IntervalMath.unionDuration(of: moving, within: interval) >= interval.duration * 0.5
    }

    static func isQuietTime(_ date: Date, settings: DetectionSettings, calendar: Calendar) -> Bool {
        guard settings.quietHoursEnabled, settings.quietHoursStart != settings.quietHoursEnd else { return false }
        let minute = calendar.minutesAfterMidnight(of: date)
        let start = settings.quietHoursStart
        let end = settings.quietHoursEnd
        if start < end {
            return minute >= start && minute < end
        }
        return minute >= start || minute < end
    }

    private static func wasHandled(_ episode: MovementEpisode, in handled: [Date], now: Date) -> Bool {
        let lower = episode.start.addingTimeInterval(-matchTolerance)
        let upper = (episode.isOngoing ? now : episode.end).addingTimeInterval(matchTolerance)
        return handled.contains { $0 >= lower && $0 <= upper }
    }

    private static func markHandled(_ episode: MovementEpisode, in state: inout ReminderState) {
        state.startHandled.append(episode.start)
        if !episode.isOngoing {
            state.endHandled.append(episode.start)
        }
    }
}

/// The kinds of reminder notifications.
enum ReminderNotification: Equatable, Sendable {
    /// "Movement detected": log the new movement.
    case movement(Reminder)
    /// "Segment still running": end a forgotten live segment.
    case staleSegment(StaleSegmentReminder)
    /// "Moving detected?" or "Stationary?" from the location points: answer True or False.
    case location(LocationPrompt)
}

/// Converts reminders to and from a notification's `userInfo`.
enum ReminderPayload {
    static let movementKind = "movement-reminder"
    static let staleKind = "stale-segment"
    static let locationKind = "location-prompt"

    static func userInfo(for reminder: Reminder) -> [String: Any] {
        var info: [String: Any] = [
            "kind": movementKind,
            "start": reminder.start.timeIntervalSince1970,
            "activity": reminder.activity.rawValue,
            "additional": reminder.additionalUnlogged,
        ]
        if let end = reminder.end {
            info["end"] = end.timeIntervalSince1970
        }
        return info
    }

    static func userInfo(for stale: StaleSegmentReminder) -> [String: Any] {
        [
            "kind": staleKind,
            "segment": stale.segmentID.uuidString,
            "type": stale.type.rawValue,
            "stoppedAt": stale.stoppedAt.timeIntervalSince1970,
        ]
    }

    static func userInfo(for prompt: LocationPrompt) -> [String: Any] {
        var info: [String: Any] = [
            "kind": locationKind,
            "point": prompt.id.uuidString,
            "question": prompt.kind.rawValue,
            "askedAt": prompt.askedAt.timeIntervalSinceReferenceDate,
            "since": prompt.since.timeIntervalSinceReferenceDate,
            "distance": prompt.distance,
        ]
        if let segmentID = prompt.segmentID {
            info["segment"] = segmentID.uuidString
        }
        return info
    }

    static func notification(from userInfo: [AnyHashable: Any]) -> ReminderNotification? {
        switch userInfo["kind"] as? String {
        case movementKind:
            return reminder(from: userInfo).map { .movement($0) }
        case locationKind:
            guard let id = (userInfo["point"] as? String).flatMap(UUID.init(uuidString:)),
                  let kind = (userInfo["question"] as? String).flatMap(LocationPromptKind.init(rawValue:)),
                  let askedAt = number(userInfo["askedAt"]),
                  let since = number(userInfo["since"]) else { return nil }
            return .location(LocationPrompt(
                id: id,
                kind: kind,
                askedAt: Date(timeIntervalSinceReferenceDate: askedAt),
                since: Date(timeIntervalSinceReferenceDate: since),
                distance: number(userInfo["distance"]) ?? 0,
                segmentID: (userInfo["segment"] as? String).flatMap(UUID.init(uuidString:))
            ))
        case staleKind:
            guard let id = (userInfo["segment"] as? String).flatMap(UUID.init(uuidString:)),
                  let type = (userInfo["type"] as? String).flatMap(MovementType.init(rawValue:)),
                  let stoppedAt = number(userInfo["stoppedAt"]) else { return nil }
            return .staleSegment(StaleSegmentReminder(segmentID: id, type: type, stoppedAt: Date(timeIntervalSince1970: stoppedAt)))
        default:
            return nil
        }
    }

    static func reminder(from userInfo: [AnyHashable: Any]) -> Reminder? {
        guard userInfo["kind"] as? String == movementKind, let start = number(userInfo["start"]) else { return nil }
        let end = number(userInfo["end"]).map { Date(timeIntervalSince1970: $0) }
        let activity = (userInfo["activity"] as? String).flatMap(DetectedActivity.init(rawValue:)) ?? .unknown
        let additional = number(userInfo["additional"]).map { Int($0) } ?? 0
        return Reminder(start: Date(timeIntervalSince1970: start), end: end, activity: activity, additionalUnlogged: additional)
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let double as Double: return double
        case let int as Int: return Double(int)
        case let string as String: return Double(string)
        default: return nil
        }
    }
}
