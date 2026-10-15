import XCTest
@testable import SegmentationCore

final class MovementTypeTests: XCTestCase {
    func testRawValuesMatchTheCSVSpecification() {
        XCTAssertEqual(
            MovementType.allCases.map(\.rawValue),
            ["stationary", "walking", "bike", "bus/tram", "train", "car", "ship", "cablecar", "other"]
        )
    }

    func testLenientParsingForImport() {
        XCTAssertEqual(MovementType(csvValue: "bus/tram"), .busTram)
        XCTAssertEqual(MovementType(csvValue: "Bus / Tram"), .busTram)
        XCTAssertEqual(MovementType(csvValue: "Velo"), .bike)
        XCTAssertEqual(MovementType(csvValue: " zu Fuss "), .walking)
        XCTAssertEqual(MovementType(csvValue: "Cable car"), .cablecar)
        XCTAssertEqual(MovementType(csvValue: "SHIP"), .ship)
        XCTAssertEqual(MovementType(csvValue: "Stillstand"), .stationary)
        XCTAssertNil(MovementType(csvValue: "plane"))
        XCTAssertNil(MovementType(csvValue: ""))
    }
}

final class SegmentBookTests: XCTestCase {
    private let now = TestClock.date("2026-10-15 12:00")

    func testSaveNewSegmentDropsSeconds() throws {
        var book = SegmentBook()
        let draft = SegmentDraft(
            start: TestClock.date("2026-10-15 08:12:47"),
            end: TestClock.date("2026-10-15 08:40:05"),
            type: .walking,
            note: "  to the station  "
        )
        let saved = try book.save(draft, now: now)

        XCTAssertEqual(saved.start, TestClock.date("2026-10-15 08:12"))
        XCTAssertEqual(saved.end, TestClock.date("2026-10-15 08:40"))
        XCTAssertEqual(saved.note, "to the station")
        XCTAssertEqual(saved.source, .manual)
        XCTAssertEqual(book.segments, [saved])
    }

    func testSaveRequiresTypeAndPositiveDuration() {
        var book = SegmentBook()
        let missingType = SegmentDraft(start: TestClock.date("2026-10-15 08:00"), end: TestClock.date("2026-10-15 08:30"))
        XCTAssertThrowsError(try book.save(missingType, now: now)) { error in
            XCTAssertEqual(error as? DraftError, .missingType)
        }

        let backwards = SegmentDraft(start: TestClock.date("2026-10-15 08:30"), end: TestClock.date("2026-10-15 08:30:59"), type: .car)
        XCTAssertThrowsError(try book.save(backwards, now: now)) { error in
            XCTAssertEqual(error as? DraftError, .endNotAfterStart)
        }
        XCTAssertTrue(book.segments.isEmpty)
    }

    func testRunningSegmentCannotStartInTheFuture() {
        let book = SegmentBook()
        let draft = SegmentDraft(start: TestClock.date("2026-10-15 12:05"), end: nil, type: .walking)
        XCTAssertEqual(book.validate(draft, now: now).errors, [.runningStartsInFuture])
    }

    func testNewSegmentEndsAnEarlierRunningSegment() throws {
        var book = SegmentBook()
        book.startLive(.walking, at: TestClock.date("2026-10-15 11:00"))
        let tram = SegmentDraft(start: TestClock.date("2026-10-15 11:20"), end: nil, type: .busTram)

        let validation = book.validate(tram, now: now)
        XCTAssertTrue(validation.canSave)
        XCTAssertEqual(validation.endsRunningSegment?.type, .walking)
        XCTAssertTrue(validation.warnings.isEmpty, "The walk is cut at 11:20, so there is no overlap")

        try book.save(tram, now: now)
        XCTAssertEqual(book.segments.count, 2)
        XCTAssertEqual(book.segments[0].type, .walking)
        XCTAssertEqual(book.segments[0].end, TestClock.date("2026-10-15 11:20"))
        XCTAssertEqual(book.running?.type, .busTram)
    }

    func testOnlyOneSegmentCanRun() {
        var book = SegmentBook()
        book.startLive(.car, at: TestClock.date("2026-10-15 11:30"))
        let earlierRunning = SegmentDraft(start: TestClock.date("2026-10-15 11:00"), end: nil, type: .walking)
        XCTAssertEqual(book.validate(earlierRunning, now: now).errors, [.anotherSegmentRunning])
    }

    func testEditingKeepsIdentityAndUpdatesTimestamp() throws {
        var book = SegmentBook(segments: [makeSegment(.car, "2026-10-15 07:00", "2026-10-15 07:30")])
        let original = book.segments[0]
        var draft = SegmentDraft(editing: original)
        draft.type = .busTram
        draft.end = TestClock.date("2026-10-15 07:45")

        let saved = try book.save(draft, now: now)
        XCTAssertEqual(saved.id, original.id)
        XCTAssertEqual(saved.createdAt, original.createdAt)
        XCTAssertEqual(saved.updatedAt, now)
        XCTAssertEqual(book.segments, [saved])
        XCTAssertEqual(saved.type, .busTram)
    }

    func testValidationWarnsAboutOverlapsAndLongSegments() {
        let book = SegmentBook(segments: [makeSegment(.train, "2026-10-15 08:00", "2026-10-15 09:00")])
        let overlapping = SegmentDraft(start: TestClock.date("2026-10-15 08:50"), end: TestClock.date("2026-10-15 09:10"), type: .walking)
        XCTAssertEqual(book.validate(overlapping, now: now).warnings, [.overlaps([book.segments[0]])])

        let long = SegmentDraft(start: TestClock.date("2026-10-14 06:00"), end: TestClock.date("2026-10-14 19:00"), type: .stationary)
        XCTAssertEqual(book.validate(long, now: now).warnings, [.veryLong])
    }

    func testStartLiveEndsTheRunningSegment() {
        var book = SegmentBook()
        book.startLive(.walking, at: TestClock.date("2026-10-15 08:00:30"))
        book.startLive(.busTram, at: TestClock.date("2026-10-15 08:07:10"))

        XCTAssertEqual(book.segments.count, 2)
        XCTAssertEqual(book.segments[0].end, TestClock.date("2026-10-15 08:07"))
        XCTAssertEqual(book.segments[1].start, TestClock.date("2026-10-15 08:07"))
        XCTAssertTrue(book.segments[1].isRunning)
        XCTAssertEqual(book.segments[1].source, .live)
    }

    func testStartLiveWithinTheSameMinuteCorrectsTheType() {
        var book = SegmentBook()
        book.startLive(.car, at: TestClock.date("2026-10-15 08:00:10"))
        book.startLive(.busTram, at: TestClock.date("2026-10-15 08:00:40"))

        XCTAssertEqual(book.segments.count, 1)
        XCTAssertEqual(book.running?.type, .busTram)
    }

    func testStopLiveLastsAtLeastOneMinute() {
        var book = SegmentBook()
        book.startLive(.walking, at: TestClock.date("2026-10-15 08:00:10"))
        let stopped = book.stopLive(at: TestClock.date("2026-10-15 08:00:50"))

        XCTAssertEqual(stopped?.end, TestClock.date("2026-10-15 08:01"))
        XCTAssertNil(book.running)
    }

    func testPreviousAndNextSegments() {
        let book = SegmentBook(segments: [
            makeSegment(.walking, "2026-10-15 08:00", "2026-10-15 08:10"),
            makeSegment(.busTram, "2026-10-15 08:10", "2026-10-15 08:30"),
            makeSegment(.stationary, "2026-10-15 08:30", "2026-10-15 12:00"),
        ])
        XCTAssertEqual(book.previous(before: TestClock.date("2026-10-15 08:30"))?.type, .busTram)
        XCTAssertEqual(book.previous(before: TestClock.date("2026-10-15 08:30"), excluding: book.segments[1].id)?.type, .walking)
        XCTAssertNil(book.previous(before: TestClock.date("2026-10-15 08:00")))
        XCTAssertEqual(book.next(after: TestClock.date("2026-10-15 08:10"))?.type, .stationary)
    }

    func testMergeAddsUpdatesAndSkipsDuplicates() {
        let existing = makeSegment(.car, "2026-10-15 07:00", "2026-10-15 07:30")
        var book = SegmentBook(segments: [existing])

        var changed = existing
        changed.type = .busTram
        let duplicateWithNewID = Segment(start: existing.start, end: existing.end, type: .car)
        let fresh = makeSegment(.walking, "2026-10-15 07:30", "2026-10-15 07:40")

        let result = book.merge([duplicateWithNewID, changed, fresh])
        XCTAssertEqual(result, MergeResult(added: 1, updated: 1, unchanged: 1))
        XCTAssertEqual(book.segments.map(\.type), [.busTram, .walking])
    }

    func testDaysWithSegmentsIncludeBothDaysOfANightSegment() {
        let book = SegmentBook(segments: [
            makeSegment(.stationary, "2026-10-14 22:00", "2026-10-15 07:00"),
            makeSegment(.walking, "2026-10-16 08:00", "2026-10-17 00:00"),
        ])
        let days = book.daysWithSegments(calendar: TestClock.calendar, now: now)
        XCTAssertEqual(days, [
            TestClock.date("2026-10-14 00:00"),
            TestClock.date("2026-10-15 00:00"),
            TestClock.date("2026-10-16 00:00"),
        ])
    }

    func testTotalsByTypeAreClippedToTheInterval() {
        let book = SegmentBook(segments: [
            makeSegment(.stationary, "2026-10-14 22:00", "2026-10-15 07:00"),
            makeSegment(.walking, "2026-10-15 07:00", "2026-10-15 07:20"),
            makeSegment(.walking, "2026-10-15 17:00", "2026-10-15 17:10"),
        ])
        let day = TestClock.calendar.dayInterval(containing: TestClock.date("2026-10-15 12:00"))
        XCTAssertEqual(book.totalsByType(within: day, now: now), [
            TypeTotal(type: .stationary, duration: 7 * 3600),
            TypeTotal(type: .walking, duration: 30 * 60),
        ])
    }

    func testTypesByDayKeepsFirstAppearanceOrder() {
        let book = SegmentBook(segments: [
            makeSegment(.walking, "2026-10-15 07:00", "2026-10-15 07:20"),
            makeSegment(.train, "2026-10-15 07:20", "2026-10-15 08:00"),
            makeSegment(.walking, "2026-10-15 08:00", "2026-10-15 08:10"),
        ])
        let month = DateInterval(start: TestClock.date("2026-10-01 00:00"), end: TestClock.date("2026-11-01 00:00"))
        let types = book.typesByDay(within: month, calendar: TestClock.calendar, now: now)
        XCTAssertEqual(types, [TestClock.date("2026-10-15 00:00"): [.walking, .train]])
    }

    func testContinuity() {
        let eight = TestClock.date("2026-10-15 08:00")
        XCTAssertEqual(Continuity.between(end: eight, start: eight), .seamless)
        XCTAssertEqual(Continuity.between(end: eight, start: eight.addingTimeInterval(300)), .gap(300))
        XCTAssertEqual(Continuity.between(end: eight, start: eight.addingTimeInterval(-120)), .overlap(120))
        XCTAssertEqual(Continuity.between(end: nil, start: eight), .running)
    }
}
