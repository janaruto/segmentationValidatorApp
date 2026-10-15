import Foundation

extension Date {
    /// Drops the seconds: 08:12:47 becomes 08:12:00.
    var flooredToMinute: Date {
        Date(timeIntervalSinceReferenceDate: (timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
    }
}

extension Calendar {
    /// The whole calendar day that contains `date`.
    func dayInterval(containing date: Date) -> DateInterval {
        let start = startOfDay(for: date)
        let end = self.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return DateInterval(start: start, end: end)
    }

    /// `date` moved to the calendar day of `day`, keeping hour and minute.
    func moving(_ date: Date, toDayOf day: Date) -> Date {
        let time = dateComponents([.hour, .minute], from: date)
        let dayStart = startOfDay(for: day)
        return self.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: dayStart) ?? dayStart
    }

    /// Combines the day of `start` with the time of day of `endTimeOfDay`.
    ///
    /// A time before the start means the segment ends on the following day (e.g. 23:30 – 00:15).
    /// The same time as the start yields a zero-length segment, which validation rejects.
    func end(forStart start: Date, endTimeOfDay: Date) -> Date {
        let start = start.flooredToMinute
        let sameDay = moving(endTimeOfDay, toDayOf: start)
        if sameDay >= start {
            return sameDay
        }
        return self.date(byAdding: .day, value: 1, to: sameDay) ?? sameDay.addingTimeInterval(86_400)
    }

    /// Minutes after midnight, e.g. 07:30 is 450.
    func minutesAfterMidnight(of date: Date) -> Int {
        let components = dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
}

/// Short, language neutral durations: "45 min", "1 h 5 min", "3 h".
enum DurationText {
    static func short(_ interval: TimeInterval) -> String {
        let totalMinutes = max(0, Int((interval / 60).rounded()))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 {
            return "\(minutes) min"
        }
        if minutes == 0 {
            return "\(hours) h"
        }
        return "\(hours) h \(minutes) min"
    }
}

enum IntervalMath {
    /// The parts of `base` that are not covered by any of `cuts`.
    static func subtract(_ cuts: [DateInterval], from base: DateInterval) -> [DateInterval] {
        var pieces = [base]
        for cut in cuts {
            var remaining: [DateInterval] = []
            for piece in pieces {
                guard cut.end > piece.start, cut.start < piece.end else {
                    remaining.append(piece)
                    continue
                }
                if cut.start > piece.start {
                    remaining.append(DateInterval(start: piece.start, end: cut.start))
                }
                if cut.end < piece.end {
                    remaining.append(DateInterval(start: cut.end, end: piece.end))
                }
            }
            pieces = remaining
        }
        return pieces
    }

    /// `interval` restricted to `bounds`, or `nil` if nothing is left.
    static func clip(_ interval: DateInterval, to bounds: DateInterval) -> DateInterval? {
        let start = max(interval.start, bounds.start)
        let end = min(interval.end, bounds.end)
        return start < end ? DateInterval(start: start, end: end) : nil
    }

    /// Length of the time both intervals share.
    static func overlap(_ a: DateInterval, _ b: DateInterval) -> TimeInterval {
        max(0, min(a.end, b.end).timeIntervalSince(max(a.start, b.start)))
    }

    /// Total time covered by `intervals` inside `bounds`, counting overlaps only once.
    static func unionDuration(of intervals: [DateInterval], within bounds: DateInterval) -> TimeInterval {
        let clipped = intervals.compactMap { clip($0, to: bounds) }.sorted { $0.start < $1.start }
        var total: TimeInterval = 0
        var current: DateInterval?
        for interval in clipped {
            if let open = current, interval.start <= open.end {
                current = DateInterval(start: open.start, end: max(open.end, interval.end))
            } else {
                if let open = current {
                    total += open.duration
                }
                current = interval
            }
        }
        if let open = current {
            total += open.duration
        }
        return total
    }
}
