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
}
#endif
