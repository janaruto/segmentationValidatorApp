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
    /// Let iOS wake the app on significant location changes (location is never stored).
    var useLocationWakeUps = false
    var suggestStationary = true

    init() {}

    private enum CodingKeys: String, CodingKey {
        case remindersEnabled, sensitivity, timing, quietHoursEnabled, quietHoursStart, quietHoursEnd
        case useLocationWakeUps, suggestStationary
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
    var lastCheckAt: Date?
    var lastOutcome: ReminderOutcome?

    mutating func prune(before cutoff: Date) {
        startHandled.removeAll { $0 < cutoff }
        endHandled.removeAll { $0 < cutoff }
    }
}

enum ReminderOutcome: String, Codable, Sendable {
    case disabled
    case noPermission
    case noMovement
    case alreadyHandled
    case quietHours
    case coolingDown
    case sent
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

/// Converts reminders to and from a notification's `userInfo`.
enum ReminderPayload {
    static let kind = "movement-reminder"

    static func userInfo(for reminder: Reminder) -> [String: Any] {
        var info: [String: Any] = [
            "kind": kind,
            "start": reminder.start.timeIntervalSince1970,
            "activity": reminder.activity.rawValue,
            "additional": reminder.additionalUnlogged,
        ]
        if let end = reminder.end {
            info["end"] = end.timeIntervalSince1970
        }
        return info
    }

    static func reminder(from userInfo: [AnyHashable: Any]) -> Reminder? {
        guard userInfo["kind"] as? String == kind, let start = number(userInfo["start"]) else { return nil }
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
