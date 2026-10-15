import Foundation

/// Tuning knobs for turning raw motion activity into movements.
struct DetectionParameters: Equatable, Sendable {
    /// Samples below this confidence never change the detected activity on their own.
    var minimumConfidence: ActivityConfidence
    /// Shorter runs are treated as noise and absorbed by their neighbours.
    var minimumRunDuration: TimeInterval
    /// Stops up to this long (traffic lights, waiting for the tram) do not end a trip.
    var maximumPause: TimeInterval
    /// Trips shorter than this never trigger a reminder.
    var minimumEpisodeDuration: TimeInterval
    /// Minimum time between two reminders.
    var reminderCooldown: TimeInterval
}

/// A stretch of time with one detected activity.
struct DetectedRun: Equatable, Sendable {
    var start: Date
    var end: Date
    var activity: DetectedActivity
    /// True for the last run when it reaches the evaluation time ("now").
    var isOngoing: Bool

    var duration: TimeInterval { end.timeIntervalSince(start) }
    var interval: DateInterval { DateInterval(start: start, end: max(start, end)) }
}

/// A trip: one or more moving runs, possibly with short pauses in between.
struct MovementEpisode: Equatable, Sendable {
    var start: Date
    var end: Date
    /// The movement may still be going on.
    var isOngoing: Bool
    var runs: [DetectedRun]

    var duration: TimeInterval { end.timeIntervalSince(start) }
    var interval: DateInterval { DateInterval(start: start, end: max(start, end)) }

    /// The moving activity with the most time in this episode.
    var dominantActivity: DetectedActivity {
        var totals: [DetectedActivity: TimeInterval] = [:]
        for run in runs where run.activity.isMoving {
            totals[run.activity, default: 0] += run.duration
        }
        let best = totals.max { lhs, rhs in
            lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key.rawValue > rhs.key.rawValue
        }
        return best?.key ?? .unknown
    }
}

/// Turns the motion coprocessor's activity samples into clean runs and trips.
///
/// The sensor is deliberately not trusted too quickly ("not too sensitive"):
/// low confidence samples alone never change the activity, very short runs are
/// absorbed by their neighbours, and short stops do not split a trip.
enum MovementDetector {
    static func runs(from samples: [ActivitySample], until end: Date, parameters: DetectionParameters) -> [DetectedRun] {
        let sorted = samples.filter { $0.start < end }.sorted { $0.start < $1.start }

        var raw: [DetectedRun] = []
        var current: (start: Date, activity: DetectedActivity)?
        // Low confidence samples announcing a change. If the change gets confirmed,
        // the run starts at the first of them instead of at the confirmation.
        var pending: (start: Date, activity: DetectedActivity)?

        for sample in sorted {
            let isKnown = sample.activity != .unknown
            let isConfident = isKnown && sample.confidence >= parameters.minimumConfidence

            if !isConfident {
                if current == nil {
                    current = (sample.start, .unknown)
                }
                if isKnown {
                    if sample.activity == current?.activity {
                        pending = nil
                    } else if pending?.activity != sample.activity {
                        pending = (sample.start, sample.activity)
                    }
                }
                continue
            }

            if let open = current, open.activity == sample.activity {
                pending = nil
                continue
            }
            let boundary = pending?.activity == sample.activity ? pending!.start : sample.start
            if let open = current, boundary > open.start {
                raw.append(DetectedRun(start: open.start, end: boundary, activity: open.activity, isOngoing: false))
            }
            current = (boundary, sample.activity)
            pending = nil
        }
        if let open = current, end > open.start {
            raw.append(DetectedRun(start: open.start, end: end, activity: open.activity, isOngoing: true))
        }
        return absorbShortRuns(raw, minimumDuration: parameters.minimumRunDuration)
    }

    /// Groups runs into trips. Stationary or unknown stretches up to `maximumPause` are bridged.
    static func episodes(from runs: [DetectedRun], parameters: DetectionParameters) -> [MovementEpisode] {
        var episodes: [MovementEpisode] = []
        var tripRuns: [DetectedRun] = []
        var pauseRuns: [DetectedRun] = []

        func pauseDuration() -> TimeInterval {
            pauseRuns.reduce(0) { $0 + $1.duration }
        }

        func closeTrip(isOngoing: Bool) {
            guard let first = tripRuns.first, let last = tripRuns.last else { return }
            episodes.append(MovementEpisode(start: first.start, end: last.end, isOngoing: isOngoing, runs: tripRuns))
            tripRuns = []
        }

        for run in runs {
            if run.activity.isMoving {
                if !tripRuns.isEmpty {
                    tripRuns += pauseRuns
                }
                pauseRuns = []
                tripRuns.append(run)
            } else if !tripRuns.isEmpty {
                pauseRuns.append(run)
                if pauseDuration() > parameters.maximumPause {
                    closeTrip(isOngoing: false)
                    pauseRuns = []
                }
            }
        }

        if let last = tripRuns.last {
            // Still moving, or only stopped briefly (e.g. at a traffic light).
            let briefStop = pauseRuns.last?.isOngoing == true && pauseDuration() <= parameters.maximumPause
            closeTrip(isOngoing: last.isOngoing || briefStop)
        }
        return episodes
    }

    /// Removes flicker: runs shorter than `minimumDuration` are merged into a neighbour.
    static func absorbShortRuns(_ input: [DetectedRun], minimumDuration: TimeInterval) -> [DetectedRun] {
        var runs = mergeAdjacent(input)
        while runs.count > 1 {
            let candidates = runs.indices.filter { runs[$0].duration < minimumDuration }
            guard let index = candidates.min(by: { runs[$0].duration < runs[$1].duration }) else { break }
            let short = runs[index]
            if index > 0, index < runs.count - 1, runs[index - 1].activity == runs[index + 1].activity {
                // A blip inside one activity: glue the three runs together.
                runs[index - 1].end = runs[index + 1].end
                runs[index - 1].isOngoing = runs[index + 1].isOngoing
                runs.removeSubrange(index...(index + 1))
            } else if index > 0 {
                runs[index - 1].end = short.end
                runs[index - 1].isOngoing = short.isOngoing
                runs.remove(at: index)
            } else {
                runs[1].start = short.start
                runs.remove(at: 0)
            }
            runs = mergeAdjacent(runs)
        }
        return runs
    }

    private static func mergeAdjacent(_ runs: [DetectedRun]) -> [DetectedRun] {
        var merged: [DetectedRun] = []
        for run in runs {
            if let last = merged.last, last.activity == run.activity, last.end >= run.start {
                merged[merged.count - 1].end = max(last.end, run.end)
                merged[merged.count - 1].isOngoing = run.isOngoing
            } else {
                merged.append(run)
            }
        }
        return merged
    }
}
