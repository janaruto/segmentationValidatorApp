import Foundation

/// Unlogged time between two segments of a day.
struct TimelineGap: Equatable, Identifiable, Sendable {
    var start: Date
    var end: Date

    var id: Date { start }
    var duration: TimeInterval { end.timeIntervalSince(start) }
}

enum TimelineEntry: Equatable, Identifiable, Sendable {
    case segment(Segment)
    case gap(TimelineGap)

    var id: String {
        switch self {
        case .segment(let segment): return "segment-\(segment.id.uuidString)"
        case .gap(let gap): return "gap-\(gap.start.timeIntervalSinceReferenceDate)"
        }
    }
}

/// Everything the day screen shows: the day's segments in order, with gaps and overlaps marked.
struct DayTimeline: Equatable, Sendable {
    let day: DateInterval
    let segments: [Segment]
    let entries: [TimelineEntry]
    /// Segments that overlap a neighbour.
    let overlappingIDs: Set<UUID>
    /// Time of the day covered by at least one segment.
    let loggedDuration: TimeInterval

    var gaps: [TimelineGap] {
        entries.compactMap { entry in
            if case .gap(let gap) = entry { return gap }
            return nil
        }
    }

    init(day date: Date, book: SegmentBook, calendar: Calendar, now: Date, minimumGap: TimeInterval = 60) {
        let interval = calendar.dayInterval(containing: date)
        let daySegments = book.segments(intersecting: interval, now: now)

        var entries: [TimelineEntry] = []
        var overlapping = Set<UUID>()
        // End of everything logged so far, and the segment it belongs to.
        var cursor: Date?
        var cursorOwner: UUID?

        for segment in daySegments {
            if let covered = cursor {
                let visibleStart = max(segment.start, interval.start)
                if visibleStart.timeIntervalSince(covered) >= minimumGap {
                    entries.append(.gap(TimelineGap(start: covered, end: visibleStart)))
                } else if segment.start < covered {
                    overlapping.insert(segment.id)
                    if let owner = cursorOwner {
                        overlapping.insert(owner)
                    }
                }
            }
            entries.append(.segment(segment))
            let visibleEnd = min(segment.effectiveEnd(now: now), interval.end)
            if cursor == nil || visibleEnd > cursor! {
                cursor = visibleEnd
                cursorOwner = segment.id
            }
        }

        self.day = interval
        self.segments = daySegments
        self.entries = entries
        self.overlappingIDs = overlapping
        self.loggedDuration = IntervalMath.unionDuration(of: daySegments.map { $0.interval(now: now) }, within: interval)
    }
}

/// Builds pre-filled drafts so that the user rarely has to type a time.
enum DraftFactory {
    /// Draft for the "add" button of a day: continues where the day's last segment ended.
    static func newDraft(on day: Date, book: SegmentBook, now: Date, calendar: Calendar) -> SegmentDraft {
        let interval = calendar.dayInterval(containing: day)
        let nowMinute = now.flooredToMinute
        let isToday = now >= interval.start && now < interval.end
        let daySegments = book.segments(intersecting: interval, now: now)

        // Something is running: the new segment most likely replaces it from now on.
        if isToday, daySegments.contains(where: { $0.isRunning }) {
            return SegmentDraft(start: nowMinute, end: nil)
        }

        let start: Date
        if let lastEnd = daySegments.compactMap({ $0.end }).max(), lastEnd < interval.end {
            start = max(lastEnd, interval.start)
        } else if isToday {
            start = max(interval.start, nowMinute.addingTimeInterval(-30 * 60))
        } else {
            start = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: interval.start) ?? interval.start
        }

        var end: Date
        if isToday, nowMinute > start {
            end = nowMinute
        } else {
            end = min(start.addingTimeInterval(30 * 60), interval.end)
        }
        if end <= start {
            end = start.addingTimeInterval(15 * 60)
        }
        return SegmentDraft(start: start, end: end)
    }

    /// Fills an unlogged gap between two segments.
    static func draft(for gap: TimelineGap) -> SegmentDraft {
        SegmentDraft(start: gap.start.flooredToMinute, end: gap.end.flooredToMinute)
    }

    /// Starts right after an existing segment.
    static func draft(after segment: Segment, book: SegmentBook, now: Date) -> SegmentDraft {
        let start = (segment.end ?? now).flooredToMinute
        var end = start.addingTimeInterval(30 * 60)
        if let next = book.next(after: segment.start, excluding: segment.id), next.start > start {
            end = next.start
        } else if now.flooredToMinute > start, now.timeIntervalSince(start) < 12 * 3600 {
            end = now.flooredToMinute
        }
        return SegmentDraft(start: start, end: end)
    }

    /// Pre-filled from a detected movement. Ongoing movements become running segments.
    static func draft(for suggestion: Suggestion) -> SegmentDraft {
        SegmentDraft(
            start: suggestion.start,
            end: suggestion.isOngoing ? nil : suggestion.end,
            type: suggestion.activity.suggestedMovementType,
            source: .suggestion,
            detectedActivity: suggestion.activity
        )
    }

    /// Pre-filled from a movement reminder notification.
    static func draft(for reminder: Reminder, now: Date) -> SegmentDraft {
        let start = reminder.start.flooredToMinute
        let end = reminder.end?.flooredToMinute ?? max(now.flooredToMinute, start.addingTimeInterval(60))
        return SegmentDraft(
            start: start,
            end: end,
            type: reminder.activity.suggestedMovementType,
            source: .reminder,
            detectedActivity: reminder.activity
        )
    }
}
