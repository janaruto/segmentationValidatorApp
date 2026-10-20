import Foundation

/// All logged segments and every change the app makes to them.
///
/// A value type without UI dependencies, so each rule can be unit tested.
struct SegmentBook: Equatable, Sendable {
    /// Sorted by start time.
    private(set) var segments: [Segment]

    init(segments: [Segment] = []) {
        self.segments = segments.sorted(by: Self.areInIncreasingOrder)
    }

    static func areInIncreasingOrder(_ a: Segment, _ b: Segment) -> Bool {
        if a.start != b.start {
            return a.start < b.start
        }
        return a.createdAt < b.createdAt
    }

    // MARK: - Queries

    /// The segment that is currently running (live logging), if any.
    var running: Segment? {
        segments.last(where: { $0.isRunning })
    }

    func segment(withID id: UUID) -> Segment? {
        segments.first(where: { $0.id == id })
    }

    /// Segments that touch `interval`, sorted by start.
    func segments(intersecting interval: DateInterval, now: Date) -> [Segment] {
        segments.filter { segment in
            let startsInside = segment.start >= interval.start && segment.start < interval.end
            let spansInto = segment.start < interval.end && segment.effectiveEnd(now: now) > interval.start
            return startsInside || spansInto
        }
    }

    /// The latest segment that starts before `date`. Shown in the editor to check continuity.
    func previous(before date: Date, excluding id: UUID? = nil) -> Segment? {
        segments.last(where: { $0.id != id && $0.start < date })
    }

    /// The first segment that starts after `date`.
    func next(after date: Date, excluding id: UUID? = nil) -> Segment? {
        segments.first(where: { $0.id != id && $0.start > date })
    }

    /// The segment logged at `date`; the one that started last if several overlap.
    func segment(at date: Date, now: Date) -> Segment? {
        // Binary search for the number of segments that start at or before `date`.
        var low = 0
        var high = segments.count
        while low < high {
            let middle = (low + high) / 2
            if segments[middle].start <= date {
                low = middle + 1
            } else {
                high = middle
            }
        }
        // Usually the latest of them; look a little further back for long, overlapping ones.
        for segment in segments[..<low].reversed().prefix(50) where segment.effectiveEnd(now: now) > date {
            return segment
        }
        return nil
    }

    // MARK: - Validation

    func validate(_ draft: SegmentDraft, now: Date) -> DraftValidation {
        var result = DraftValidation()
        let start = draft.start.flooredToMinute
        let end = draft.end?.flooredToMinute

        if draft.type == nil {
            result.errors.append(.missingType)
        }
        if let end, end <= start {
            result.errors.append(.endNotAfterStart)
        }
        if end == nil, start > now {
            result.errors.append(.runningStartsInFuture)
        }
        if end == nil, segments.contains(where: { $0.isRunning && $0.id != draft.editingID && $0.start >= start }) {
            result.errors.append(.anotherSegmentRunning)
        }

        let endedRunning = runningSegments(endedBy: start, excluding: draft.editingID).last
        result.endsRunningSegment = endedRunning

        if start > now.addingTimeInterval(60) {
            result.warnings.append(.startsInFuture)
        }
        if let end, end.timeIntervalSince(start) > 12 * 3600 {
            result.warnings.append(.veryLong)
        }
        let draftInterval = DateInterval(start: start, end: max(start, end ?? max(now, start)))
        let endedIDs = Set(runningSegments(endedBy: start, excluding: draft.editingID).map(\.id))
        let overlapping = segments.filter { other in
            guard other.id != draft.editingID, !endedIDs.contains(other.id) else { return false }
            return IntervalMath.overlap(other.interval(now: now), draftInterval) > 0
        }
        if !overlapping.isEmpty {
            result.warnings.append(.overlaps(overlapping))
        }
        return result
    }

    /// Running segments that end when a segment starting at `start` is saved.
    private func runningSegments(endedBy start: Date, excluding id: UUID?) -> [Segment] {
        segments.filter { $0.isRunning && $0.id != id && $0.start < start }
    }

    // MARK: - Changes

    /// Saves a draft as a new segment or as changes to the edited one.
    ///
    /// Only one thing can happen at a time: running segments that started earlier
    /// are ended where the saved segment starts.
    @discardableResult
    mutating func save(_ draft: SegmentDraft, now: Date) throws -> Segment {
        let validation = validate(draft, now: now)
        if let error = validation.errors.first {
            throw error
        }
        guard let type = draft.type else {
            throw DraftError.missingType
        }
        let start = draft.start.flooredToMinute
        let end = draft.end?.flooredToMinute

        let saved: Segment
        if let id = draft.editingID, let index = segments.firstIndex(where: { $0.id == id }) {
            var segment = segments[index]
            segment.start = start
            segment.end = end
            segment.type = type
            segment.note = draft.trimmedNote
            segment.updatedAt = now
            segments[index] = segment
            saved = segment
        } else {
            saved = Segment(
                id: draft.editingID ?? UUID(),
                start: start,
                end: end,
                type: type,
                note: draft.trimmedNote,
                source: draft.source,
                detectedActivity: draft.detectedActivity,
                createdAt: now
            )
            segments.append(saved)
        }

        for index in segments.indices where segments[index].isRunning && segments[index].id != saved.id && segments[index].start < start {
            segments[index].end = start
            segments[index].updatedAt = now
        }
        sortSegments()
        return saved
    }

    @discardableResult
    mutating func delete(id: UUID) -> Segment? {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return nil }
        return segments.remove(at: index)
    }

    /// Puts a segment back, e.g. to undo a delete.
    mutating func insert(_ segment: Segment) {
        segments.removeAll { $0.id == segment.id }
        segments.append(segment)
        sortSegments()
    }

    mutating func removeAll() {
        segments.removeAll()
    }

    /// Live logging: starts a running segment now and ends the one that was running.
    @discardableResult
    mutating func startLive(
        _ type: MovementType,
        at date: Date,
        source: Segment.Source = .live,
        detectedActivity: DetectedActivity? = nil
    ) -> Segment {
        let start = date.flooredToMinute
        // Picking another type within the same minute just corrects the running segment.
        if let index = segments.firstIndex(where: { $0.isRunning && $0.start >= start }) {
            segments[index].type = type
            segments[index].updatedAt = date
            return segments[index]
        }
        for index in segments.indices where segments[index].isRunning {
            segments[index].end = start
            segments[index].updatedAt = date
        }
        let segment = Segment(start: start, end: nil, type: type, source: source, detectedActivity: detectedActivity, createdAt: date)
        segments.append(segment)
        sortSegments()
        return segment
    }

    /// Live logging: ends the running segment now (it lasts at least one minute).
    @discardableResult
    mutating func stopLive(at date: Date) -> Segment? {
        var stopped: Segment?
        for index in segments.indices where segments[index].isRunning {
            segments[index].end = max(date.flooredToMinute, segments[index].start.addingTimeInterval(60))
            segments[index].updatedAt = date
            stopped = segments[index]
        }
        return stopped
    }

    /// Adds imported segments. Known ids are updated, identical content is skipped.
    mutating func merge(_ imported: [Segment]) -> MergeResult {
        var result = MergeResult()
        for segment in imported {
            if let index = segments.firstIndex(where: { $0.id == segment.id }) {
                if segments[index].hasSameContent(as: segment) {
                    result.unchanged += 1
                } else {
                    segments[index] = segment
                    result.updated += 1
                }
            } else if segments.contains(where: { $0.hasSameContent(as: segment) }) {
                result.unchanged += 1
            } else {
                segments.append(segment)
                result.added += 1
            }
        }
        sortSegments()
        return result
    }

    private mutating func sortSegments() {
        segments.sort(by: Self.areInIncreasingOrder)
    }

    // MARK: - Overviews

    /// Start of every day that has at least one segment.
    func daysWithSegments(calendar: Calendar, now: Date) -> Set<Date> {
        var days = Set<Date>()
        for segment in segments {
            for day in Self.days(touchedBy: segment, calendar: calendar, now: now) {
                days.insert(day)
            }
        }
        return days
    }

    /// For each day in `interval`: the distinct movement types logged that day, in order.
    func typesByDay(within interval: DateInterval, calendar: Calendar, now: Date) -> [Date: [MovementType]] {
        var result: [Date: [MovementType]] = [:]
        for segment in segments(intersecting: interval, now: now) {
            for day in Self.days(touchedBy: segment, calendar: calendar, now: now) where interval.contains(day) && day < interval.end {
                if !(result[day] ?? []).contains(segment.type) {
                    result[day, default: []].append(segment.type)
                }
            }
        }
        return result
    }

    /// Logged time per movement type inside `interval`, longest first.
    func totalsByType(within interval: DateInterval, now: Date) -> [TypeTotal] {
        var totals: [MovementType: TimeInterval] = [:]
        for segment in segments {
            guard let clipped = IntervalMath.clip(segment.interval(now: now), to: interval) else { continue }
            totals[segment.type, default: 0] += clipped.duration
        }
        return MovementType.allCases
            .compactMap { type in totals[type].map { TypeTotal(type: type, duration: $0) } }
            .sorted { $0.duration > $1.duration }
    }

    /// Every calendar day a segment touches. Capped so broken data cannot loop forever.
    private static func days(touchedBy segment: Segment, calendar: Calendar, now: Date) -> [Date] {
        let lastMoment = max(segment.start, segment.effectiveEnd(now: now).addingTimeInterval(-1))
        let lastDay = calendar.startOfDay(for: lastMoment)
        var day = calendar.startOfDay(for: segment.start)
        var days: [Date] = []
        while day <= lastDay, days.count < 62 {
            days.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return days
    }
}

struct MergeResult: Equatable, Sendable {
    var added = 0
    var updated = 0
    var unchanged = 0
}

struct TypeTotal: Equatable, Sendable {
    var type: MovementType
    var duration: TimeInterval
}
