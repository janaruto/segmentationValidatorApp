import Foundation
@testable import SegmentationCore

/// Fixed time zone and calendar so the tests behave the same on every machine.
enum TestClock {
    static let timeZone = TimeZone(identifier: "Europe/Zurich")!

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        return calendar
    }

    /// Parses "2026-10-15 08:12" or "2026-10-15 08:12:30" in Zurich time.
    static func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = text.count > 16 ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd HH:mm"
        guard let date = formatter.date(from: text) else {
            fatalError("Invalid test date: \(text)")
        }
        return date
    }
}

func makeSegment(
    _ type: MovementType,
    _ start: String,
    _ end: String?,
    note: String = "",
    source: Segment.Source = .manual
) -> Segment {
    Segment(
        start: TestClock.date(start),
        end: end.map { TestClock.date($0) },
        type: type,
        note: note,
        source: source,
        createdAt: TestClock.date(start)
    )
}

func makeSample(_ time: String, _ activity: DetectedActivity, _ confidence: ActivityConfidence = .high) -> ActivitySample {
    ActivitySample(start: TestClock.date(time), activity: activity, confidence: confidence)
}

func makeRun(_ activity: DetectedActivity, _ start: String, _ end: String, ongoing: Bool = false) -> DetectedRun {
    DetectedRun(start: TestClock.date(start), end: TestClock.date(end), activity: activity, isOngoing: ongoing)
}
