import XCTest
@testable import SegmentationCore

final class DayTimelineTests: XCTestCase {
    private let calendar = TestClock.calendar
    private let now = TestClock.date("2026-10-15 13:00")

    private func timeline(_ day: String, _ segments: [Segment], now: Date? = nil) -> DayTimeline {
        DayTimeline(day: TestClock.date(day), book: SegmentBook(segments: segments), calendar: calendar, now: now ?? self.now)
    }

    func testGapsAreInsertedBetweenSegments() {
        let result = timeline("2026-10-15 00:00", [
            makeSegment(.walking, "2026-10-15 08:00", "2026-10-15 08:10"),
            makeSegment(.busTram, "2026-10-15 08:15", "2026-10-15 08:30"),
            makeSegment(.stationary, "2026-10-15 08:30", "2026-10-15 12:00"),
        ])
        XCTAssertEqual(result.gaps, [TimelineGap(start: TestClock.date("2026-10-15 08:10"), end: TestClock.date("2026-10-15 08:15"))])
        XCTAssertEqual(result.entries.count, 4)
        XCTAssertTrue(result.overlappingIDs.isEmpty)
    }

    func testOverlappingSegmentsAreMarked() {
        let walk = makeSegment(.walking, "2026-10-15 08:00", "2026-10-15 08:20")
        let tram = makeSegment(.busTram, "2026-10-15 08:15", "2026-10-15 08:30")
        let result = timeline("2026-10-15 00:00", [walk, tram])
        XCTAssertEqual(result.overlappingIDs, [walk.id, tram.id])
        XCTAssertTrue(result.gaps.isEmpty)
        XCTAssertEqual(result.loggedDuration, 30 * 60, "Overlapping time is counted once")
    }

    func testNightSegmentShowsOnBothDays() {
        let night = makeSegment(.stationary, "2026-10-14 22:00", "2026-10-15 07:00")
        let evening = timeline("2026-10-14 00:00", [night])
        let morning = timeline("2026-10-15 00:00", [night])
        XCTAssertEqual(evening.segments, [night])
        XCTAssertEqual(morning.segments, [night])
        XCTAssertEqual(evening.loggedDuration, 2 * 3600)
        XCTAssertEqual(morning.loggedDuration, 7 * 3600)
    }

    func testRunningSegmentCountsUntilNow() {
        let running = Segment(start: TestClock.date("2026-10-15 12:30"), end: nil, type: .walking)
        let result = timeline("2026-10-15 00:00", [running])
        XCTAssertEqual(result.loggedDuration, 30 * 60)
    }

    func testOtherDaysAreIgnored() {
        let result = timeline("2026-10-16 00:00", [makeSegment(.walking, "2026-10-15 08:00", "2026-10-15 08:10")])
        XCTAssertTrue(result.entries.isEmpty)
    }
}

final class DraftFactoryTests: XCTestCase {
    private let calendar = TestClock.calendar

    func testNewDraftContinuesAfterTheLastSegmentOfAPastDay() {
        let book = SegmentBook(segments: [
            makeSegment(.walking, "2026-10-14 08:00", "2026-10-14 08:10"),
            makeSegment(.busTram, "2026-10-14 08:10", "2026-10-14 08:40"),
        ])
        let draft = DraftFactory.newDraft(on: TestClock.date("2026-10-14 15:00"), book: book, now: TestClock.date("2026-10-15 12:00"), calendar: calendar)
        XCTAssertEqual(draft.start, TestClock.date("2026-10-14 08:40"))
        XCTAssertEqual(draft.end, TestClock.date("2026-10-14 09:10"))
        XCTAssertNil(draft.type)
    }

    func testNewDraftForAnEmptyPastDayStartsAtEight() {
        let draft = DraftFactory.newDraft(on: TestClock.date("2026-10-13 00:00"), book: SegmentBook(), now: TestClock.date("2026-10-15 12:00"), calendar: calendar)
        XCTAssertEqual(draft.start, TestClock.date("2026-10-13 08:00"))
        XCTAssertEqual(draft.end, TestClock.date("2026-10-13 08:30"))
    }

    func testNewDraftForTodayEndsNow() {
        let book = SegmentBook(segments: [makeSegment(.walking, "2026-10-15 08:00", "2026-10-15 08:10")])
        let draft = DraftFactory.newDraft(on: TestClock.date("2026-10-15 00:00"), book: book, now: TestClock.date("2026-10-15 12:00:30"), calendar: calendar)
        XCTAssertEqual(draft.start, TestClock.date("2026-10-15 08:10"))
        XCTAssertEqual(draft.end, TestClock.date("2026-10-15 12:00"))
    }

    func testNewDraftForAnEmptyTodayCoversTheLastHalfHour() {
        let draft = DraftFactory.newDraft(on: TestClock.date("2026-10-15 00:00"), book: SegmentBook(), now: TestClock.date("2026-10-15 12:00:30"), calendar: calendar)
        XCTAssertEqual(draft.start, TestClock.date("2026-10-15 11:30"))
        XCTAssertEqual(draft.end, TestClock.date("2026-10-15 12:00"))
    }

    func testNewDraftWhileSomethingRunsStartsNowAndRuns() {
        var book = SegmentBook()
        book.startLive(.walking, at: TestClock.date("2026-10-15 11:00"))
        let draft = DraftFactory.newDraft(on: TestClock.date("2026-10-15 00:00"), book: book, now: TestClock.date("2026-10-15 12:00:30"), calendar: calendar)
        XCTAssertEqual(draft.start, TestClock.date("2026-10-15 12:00"))
        XCTAssertNil(draft.end)
    }

    func testDraftForGapAndAfterSegment() {
        let gap = TimelineGap(start: TestClock.date("2026-10-15 08:10"), end: TestClock.date("2026-10-15 08:15"))
        let gapDraft = DraftFactory.draft(for: gap)
        XCTAssertEqual(gapDraft.start, gap.start)
        XCTAssertEqual(gapDraft.end, gap.end)

        let walk = makeSegment(.walking, "2026-10-15 08:00", "2026-10-15 08:10")
        let tram = makeSegment(.busTram, "2026-10-15 08:30", "2026-10-15 09:00")
        let after = DraftFactory.draft(after: walk, book: SegmentBook(segments: [walk, tram]), now: TestClock.date("2026-10-15 12:00"))
        XCTAssertEqual(after.start, TestClock.date("2026-10-15 08:10"))
        XCTAssertEqual(after.end, TestClock.date("2026-10-15 08:30"))
    }

    func testDraftForReminderPrefillsTimesAndType() {
        let reminder = Reminder(start: TestClock.date("2026-10-15 08:12:40"), end: nil, activity: .walking)
        let draft = DraftFactory.draft(for: reminder, now: TestClock.date("2026-10-15 08:31:10"))
        XCTAssertEqual(draft.start, TestClock.date("2026-10-15 08:12"))
        XCTAssertEqual(draft.end, TestClock.date("2026-10-15 08:31"))
        XCTAssertEqual(draft.type, .walking)
        XCTAssertEqual(draft.source, .reminder)
        XCTAssertEqual(draft.detectedActivity, .walking)

        let vehicle = Reminder(start: TestClock.date("2026-10-15 08:12"), end: TestClock.date("2026-10-15 08:40"), activity: .automotive)
        let vehicleDraft = DraftFactory.draft(for: vehicle, now: TestClock.date("2026-10-15 09:00"))
        XCTAssertNil(vehicleDraft.type, "The phone cannot tell car, bus and train apart")
        XCTAssertEqual(vehicleDraft.end, TestClock.date("2026-10-15 08:40"))
    }

    func testDraftForOngoingSuggestionIsRunning() {
        let suggestion = Suggestion(start: TestClock.date("2026-10-15 08:12"), end: TestClock.date("2026-10-15 08:30"), activity: .cycling, isOngoing: true)
        let draft = DraftFactory.draft(for: suggestion)
        XCTAssertNil(draft.end)
        XCTAssertEqual(draft.type, .bike)
        XCTAssertEqual(draft.source, .suggestion)
    }
}

final class DateMathTests: XCTestCase {
    private let calendar = TestClock.calendar

    func testEndBeforeStartMeansNextDay() {
        let start = TestClock.date("2026-10-15 23:30")
        XCTAssertEqual(calendar.end(forStart: start, endTimeOfDay: TestClock.date("2026-01-01 00:15")), TestClock.date("2026-10-16 00:15"))
        XCTAssertEqual(calendar.end(forStart: start, endTimeOfDay: TestClock.date("2026-01-01 23:45")), TestClock.date("2026-10-15 23:45"))
        XCTAssertEqual(calendar.end(forStart: start, endTimeOfDay: TestClock.date("2026-01-01 23:30")), start, "Same time is a zero-length segment")
    }

    func testMovingKeepsTheTimeOfDay() {
        let moved = calendar.moving(TestClock.date("2026-10-15 08:12"), toDayOf: TestClock.date("2026-10-20 17:00"))
        XCTAssertEqual(moved, TestClock.date("2026-10-20 08:12"))
    }

    func testDurationText() {
        XCTAssertEqual(DurationText.short(0), "0 min")
        XCTAssertEqual(DurationText.short(59.6), "1 min")
        XCTAssertEqual(DurationText.short(45 * 60), "45 min")
        XCTAssertEqual(DurationText.short(65 * 60), "1 h 5 min")
        XCTAssertEqual(DurationText.short(120 * 60), "2 h")
    }

    func testIntervalSubtraction() {
        let base = DateInterval(start: TestClock.date("2026-10-15 08:00"), end: TestClock.date("2026-10-15 09:00"))
        let cuts = [
            DateInterval(start: TestClock.date("2026-10-15 08:10"), end: TestClock.date("2026-10-15 08:20")),
            DateInterval(start: TestClock.date("2026-10-15 08:50"), end: TestClock.date("2026-10-15 09:30")),
        ]
        XCTAssertEqual(IntervalMath.subtract(cuts, from: base), [
            DateInterval(start: TestClock.date("2026-10-15 08:00"), end: TestClock.date("2026-10-15 08:10")),
            DateInterval(start: TestClock.date("2026-10-15 08:20"), end: TestClock.date("2026-10-15 08:50")),
        ])
    }
}
