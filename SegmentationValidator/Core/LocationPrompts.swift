import Foundation

/// A question sent because of a new location point: "Moving detected?" or "Stationary?".
struct LocationPrompt: Codable, Equatable, Identifiable, Sendable {
    /// The id of the location point that led to the question.
    var id: UUID
    var kind: LocationPromptKind
    /// When that point was taken.
    var askedAt: Date
    /// Moving: the last time the user was still at the old place (the movement started after it).
    /// Stationary: the first point at the new place (the user arrived at or before it).
    var since: Date
    /// The distance that led to the question, in meters.
    var distance: Double
    /// The segment that was running when the question was asked.
    var segmentID: UUID?
}

/// What the location logic remembers between two points (stored in UserDefaults).
struct LocationPromptState: Codable, Equatable, Sendable {
    /// The newest point, accurate or not.
    var latest: LocationPoint?
    /// The newest point that was accurate enough to compare with.
    var previous: LocationPoint?
    /// The running segment the fields below belong to.
    var segmentID: UUID?
    /// While not moving: where the user stays, the reference for "moved more than 400 m".
    var anchor: LocationPoint?
    /// While not moving: the newest point that was still close to `anchor`.
    var lastNearAnchor: LocationPoint?
    /// While moving: the first point of the current stop.
    var stopStart: LocationPoint?
    /// "Moving detected?" was asked; no new question until the user stays somewhere again.
    var movingAsked = false
    /// "Stationary?" was asked; no new question until the user moves on.
    var stationaryAsked = false
    /// The newest question, until it is answered.
    var pending: LocationPrompt?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case latest, previous, segmentID, anchor, lastNearAnchor, stopStart, movingAsked, stationaryAsked, pending
    }

    // Lenient decoding, so that state written by another app version never gets lost.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        latest = try? container.decodeIfPresent(LocationPoint.self, forKey: .latest)
        previous = try? container.decodeIfPresent(LocationPoint.self, forKey: .previous)
        segmentID = try? container.decodeIfPresent(UUID.self, forKey: .segmentID)
        anchor = try? container.decodeIfPresent(LocationPoint.self, forKey: .anchor)
        lastNearAnchor = try? container.decodeIfPresent(LocationPoint.self, forKey: .lastNearAnchor)
        stopStart = try? container.decodeIfPresent(LocationPoint.self, forKey: .stopStart)
        movingAsked = (try? container.decodeIfPresent(Bool.self, forKey: .movingAsked)) ?? false
        stationaryAsked = (try? container.decodeIfPresent(Bool.self, forKey: .stationaryAsked)) ?? false
        pending = try? container.decodeIfPresent(LocationPrompt.self, forKey: .pending)
    }
}

/// Decides after every location point whether to ask "Moving detected?" or "Stationary?".
///
/// - Not moving (a stationary segment or none is running): "Moving detected?" when the point is
///   more than `movingDistance` away from the previous point, or from the place where the user
///   stayed (so that slow walks are noticed too).
/// - A moving segment is running: "Stationary?" when the point is within `stationaryDistance`
///   of the previous point, i.e. the user hardly moved for one interval.
///
/// Each question is asked once. A new one follows only after the situation changed: the user
/// stayed somewhere again, moved on, or started another segment.
enum LocationPromptEngine {
    /// Points less accurate than this (meters) are stored but not compared.
    static let maximumAccuracy: Double = 100
    /// A new "Moving detected?" this soon after an unanswered one belongs to the same trip
    /// (e.g. after a traffic jam) and keeps the original start.
    static let repeatWindow: TimeInterval = 20 * 60

    struct Result: Equatable, Sendable {
        var prompt: LocationPrompt?
        var state: LocationPromptState
    }

    static func evaluate(
        point: LocationPoint,
        running: Segment?,
        state previous: LocationPromptState,
        settings: DetectionSettings,
        calendar: Calendar
    ) -> Result {
        var state = previous
        state.latest = point
        guard point.accuracy >= 0, point.accuracy <= maximumAccuracy else {
            return Result(prompt: nil, state: state)
        }
        let last = state.previous
        state.previous = point

        if state.segmentID != running?.id {
            // Another segment started (or the running one ended): compare from scratch.
            state.segmentID = running?.id
            state.anchor = nil
            state.lastNearAnchor = nil
            state.stopStart = nil
            state.movingAsked = false
            state.stationaryAsked = false
        }

        let canAsk = settings.locationPrompts
            && !ReminderEngine.isQuietTime(point.timestamp, settings: settings, calendar: calendar)
        if let running, running.type.isMoving {
            state.anchor = nil
            state.lastNearAnchor = nil
            state.movingAsked = false
            return evaluateMoving(point: point, last: last, running: running, state: state, settings: settings, canAsk: canAsk)
        }
        state.stopStart = nil
        state.stationaryAsked = false
        return evaluateStaying(point: point, last: last, running: running, state: state, settings: settings, canAsk: canAsk)
    }

    /// Not moving: has the user left the place?
    private static func evaluateStaying(
        point: LocationPoint,
        last: LocationPoint?,
        running: Segment?,
        state: LocationPromptState,
        settings: DetectionSettings,
        canAsk: Bool
    ) -> Result {
        var state = state
        let near = Double(settings.stationaryDistance)
        guard let anchor = state.anchor else {
            state.anchor = point
            state.lastNearAnchor = point
            return Result(prompt: nil, state: state)
        }

        let fromAnchor = anchor.distance(to: point)
        if fromAnchor <= near {
            state.lastNearAnchor = point
            state.movingAsked = false
            return Result(prompt: nil, state: state)
        }

        let fromLast = last.map { $0.distance(to: point) } ?? fromAnchor
        let moved = max(fromAnchor, fromLast)
        if !state.movingAsked, canAsk, moved > Double(settings.movingDistance) {
            var since = (state.lastNearAnchor ?? anchor).timestamp
            // Asked before and not answered yet: it is still the same movement.
            if let pending = state.pending,
               pending.kind == .moving,
               pending.segmentID == running?.id,
               point.timestamp.timeIntervalSince(pending.askedAt) < repeatWindow {
                since = min(since, pending.since)
            }
            let prompt = LocationPrompt(
                id: point.id,
                kind: .moving,
                askedAt: point.timestamp,
                since: since,
                distance: moved,
                segmentID: running?.id
            )
            state.movingAsked = true
            state.pending = prompt
            return Result(prompt: prompt, state: state)
        }

        if let last, fromLast <= near {
            // The user stays at a new place: compare the next points with it.
            state.anchor = last
            state.lastNearAnchor = point
            state.movingAsked = false
        }
        return Result(prompt: nil, state: state)
    }

    /// A moving segment runs: has the user stopped?
    private static func evaluateMoving(
        point: LocationPoint,
        last: LocationPoint?,
        running: Segment,
        state: LocationPromptState,
        settings: DetectionSettings,
        canAsk: Bool
    ) -> Result {
        var state = state
        let near = Double(settings.stationaryDistance)
        // Only compare points of this segment, so the user had a whole interval to move.
        guard let last, last.timestamp >= running.start.addingTimeInterval(-60) else {
            state.stopStart = nil
            return Result(prompt: nil, state: state)
        }

        let stop: LocationPoint
        if let start = state.stopStart, start.distance(to: point) <= near {
            stop = start
        } else if last.distance(to: point) <= near {
            stop = last
            state.stopStart = last
        } else {
            state.stopStart = nil
            state.stationaryAsked = false
            return Result(prompt: nil, state: state)
        }

        guard !state.stationaryAsked, canAsk else {
            return Result(prompt: nil, state: state)
        }
        let prompt = LocationPrompt(
            id: point.id,
            kind: .stationary,
            askedAt: point.timestamp,
            since: max(stop.timestamp, running.start),
            distance: stop.distance(to: point),
            segmentID: running.id
        )
        state.stationaryAsked = true
        state.pending = prompt
        return Result(prompt: prompt, state: state)
    }

    /// Refines the start of a confirmed movement with the motion sensor: the first movement
    /// it saw after the user was last at the old place.
    static func departure(for prompt: LocationPrompt, runs: [DetectedRun]) -> DetectedRun? {
        guard var run = runs.first(where: { run in
            run.activity.isMoving && run.end > prompt.since && run.start < prompt.askedAt
        }) else {
            return nil
        }
        run.start = max(run.start, prompt.since)
        return run
    }
}
