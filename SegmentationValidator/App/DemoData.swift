#if DEBUG
import Foundation

/// Sample data for trying out the app and for screenshots. Only part of debug builds.
///
/// Launch arguments (e.g. in the Xcode scheme or `xcrun simctl launch … -debugSeedDemoData YES`):
/// - `-debugSeedDemoData YES`   fill an empty app with two realistic days
/// - `-debugFakeDetections YES` pretend the motion sensor detected some movements today
/// - `-debugShowYesterday YES`  open yesterday instead of today
/// - `-debugInitialTab history|export|settings`
/// - `-debugOpenEditor reminder|new`
/// - `-debugSeedLocationPoints YES` only add location points for today and yesterday (no segments)
/// - `-debugLocationTracking YES` turn on the location points (grant the permission first)
/// - `-debugLocationPrompt YES`  show a question card ("Stationary?" while a moving segment runs)
/// - `-debugMovingAnswer YES`    open the "How are you moving?" sheet
/// - `-debugOpenMap YES`         open the map of the shown day
enum DemoData {
    static func segments(now: Date, calendar: Calendar) -> [Segment] {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today.addingTimeInterval(-86_400)
        var segments: [Segment] = []

        func at(_ day: Date, _ hour: Int, _ minute: Int) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }
        func add(_ type: MovementType, _ start: Date, _ end: Date?, note: String = "", source: Segment.Source = .manual) {
            segments.append(Segment(start: start, end: end, type: type, note: note, source: source, createdAt: start))
        }

        // Yesterday: a commuter day with a short gap while waiting for the train.
        add(.walking, at(yesterday, 7, 38), at(yesterday, 7, 47))
        add(.busTram, at(yesterday, 7, 47), at(yesterday, 8, 6), note: "Tram 11")
        add(.train, at(yesterday, 8, 12), at(yesterday, 8, 41), source: .reminder)
        add(.walking, at(yesterday, 8, 41), at(yesterday, 8, 50), source: .suggestion)
        add(.stationary, at(yesterday, 8, 50), at(yesterday, 12, 5), note: "Office")
        add(.bike, at(yesterday, 12, 5), at(yesterday, 12, 20), source: .suggestion)
        add(.stationary, at(yesterday, 12, 20), at(yesterday, 17, 30))
        add(.train, at(yesterday, 17, 30), at(yesterday, 18, 1))
        add(.ship, at(yesterday, 18, 30), at(yesterday, 19, 15), note: "Lake Zurich")
        add(.cablecar, at(yesterday, 19, 25), at(yesterday, 19, 35))

        // Today, relative to now, ending with a running segment.
        let minute: TimeInterval = 60
        let base = now.flooredToMinute
        add(.stationary, at(yesterday, 21, 0), base - 95 * minute, note: "Home")
        add(.walking, base - 95 * minute, base - 84 * minute, source: .reminder)
        add(.busTram, base - 84 * minute, base - 60 * minute)
        add(.walking, base - 52 * minute, base - 40 * minute)
        add(.train, base - 40 * minute, nil, source: .live)
        return segments
    }

    /// Pretend detections for today: a walk that is not logged yet and an unknown vehicle ride.
    static func detectedRuns(now: Date) -> [DetectedRun] {
        let base = now.flooredToMinute
        let minute: TimeInterval = 60
        return [
            DetectedRun(start: base - 60 * minute, end: base - 52 * minute, activity: .walking, isOngoing: false),
            DetectedRun(start: base - 52 * minute, end: base - 40 * minute, activity: .walking, isOngoing: false),
            DetectedRun(start: base - 40 * minute, end: now, activity: .automotive, isOngoing: true),
            DetectedRun(start: base - 200 * minute, end: base - 180 * minute, activity: .automotive, isOngoing: false),
        ]
    }

    static func reminder(now: Date) -> Reminder {
        Reminder(start: now.flooredToMinute - 12 * 60, end: nil, activity: .walking)
    }

    /// A location point every 5 minutes along today's demo segments in Zurich.
    static func locationPoints(now: Date) -> [LocationPoint] {
        let base = now.flooredToMinute
        let home = (47.3925, 8.5235)
        let tramStop = (47.3911, 8.5302)
        let bellevue = (47.3668, 8.5452)
        let mainStation = (47.3779, 8.5402)
        let winterthur = (47.4999, 8.7236)
        // (minutes relative to now, position): the path follows the demo segments.
        let waypoints: [(Double, (Double, Double))] = [
            (-180, home), (-95, home), (-84, tramStop), (-60, bellevue), (-52, bellevue),
            (-40, mainStation), (-6, winterthur), (0, winterthur),
        ]
        func position(at minute: Double) -> (Double, Double) {
            for (from, to) in zip(waypoints, waypoints.dropFirst()) where minute <= to.0 {
                let fraction = to.0 == from.0 ? 0 : (minute - from.0) / (to.0 - from.0)
                return (
                    from.1.0 + (to.1.0 - from.1.0) * fraction,
                    from.1.1 + (to.1.1 - from.1.1) * fraction
                )
            }
            return winterthur
        }
        return stride(from: -180, through: 0, by: 5).enumerated().map { index, minute in
            let (latitude, longitude) = position(at: Double(minute))
            // A little GPS noise (about 10 m), the same on every run.
            let jitter = Double((index * 37) % 7 - 3) * 0.00004
            return LocationPoint(
                timestamp: base.addingTimeInterval(Double(minute) * 60),
                latitude: latitude + jitter,
                longitude: longitude - jitter,
                accuracy: Double(5 + (index * 13) % 11),
                trigger: .interval
            )
        }
    }

    /// "Stationary?" while a moving segment runs (the train just stopped), otherwise "Moving detected?".
    static func locationPrompt(now: Date, running: Segment?) -> LocationPrompt {
        let base = now.flooredToMinute
        if let running, running.type.isMoving {
            return LocationPrompt(id: UUID(), kind: .stationary, askedAt: base, since: base - 5 * 60, distance: 40, segmentID: running.id)
        }
        return LocationPrompt(id: UUID(), kind: .moving, askedAt: base, since: base - 12 * 60, distance: 650, segmentID: running?.id)
    }
}
#endif
