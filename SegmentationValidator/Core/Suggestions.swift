import Foundation

/// A detected movement that is not logged yet. Shown on the day screen so it can be added with one tap.
struct Suggestion: Equatable, Identifiable, Sendable {
    var start: Date
    var end: Date
    var activity: DetectedActivity
    /// The movement is still going on.
    var isOngoing: Bool

    /// Stable key, also used to remember dismissed suggestions.
    var id: String {
        "\(activity.rawValue)@\(Int((start.timeIntervalSince1970 / 60).rounded(.down)))"
    }

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

enum SuggestionBuilder {
    static let minimumMovingDuration: TimeInterval = 3 * 60
    static let minimumStationaryDuration: TimeInterval = 15 * 60

    /// Detected runs inside `bounds` minus everything that is already logged.
    static func suggestions(
        runs: [DetectedRun],
        book: SegmentBook,
        within bounds: DateInterval,
        dismissed: Set<String>,
        includeStationary: Bool,
        now: Date
    ) -> [Suggestion] {
        let logged = book.segments.map { $0.interval(now: now) }
        var suggestions: [Suggestion] = []
        for run in runs where run.activity != .unknown {
            if run.activity == .stationary && !includeStationary {
                continue
            }
            guard let clipped = IntervalMath.clip(run.interval, to: bounds) else { continue }
            let minimum = run.activity == .stationary ? minimumStationaryDuration : minimumMovingDuration
            for piece in IntervalMath.subtract(logged, from: clipped) {
                let start = piece.start.flooredToMinute
                let end = piece.end.flooredToMinute
                guard end.timeIntervalSince(start) >= minimum else { continue }
                let reachesNow = run.isOngoing && piece.end >= run.end && run.end >= now.addingTimeInterval(-120)
                let suggestion = Suggestion(start: start, end: end, activity: run.activity, isOngoing: reachesNow)
                if !dismissed.contains(suggestion.id) {
                    suggestions.append(suggestion)
                }
            }
        }
        return suggestions.sorted { $0.start < $1.start }
    }
}
