import XCTest
@testable import SegmentationCore

final class MovementDetectorTests: XCTestCase {
    private let medium = Sensitivity.medium.parameters

    func testConfidentChangesCreateRuns() {
        let samples = [
            makeSample("2026-10-15 07:00", .stationary),
            makeSample("2026-10-15 08:00", .walking),
            makeSample("2026-10-15 08:10", .automotive),
            makeSample("2026-10-15 08:40", .stationary),
        ]
        let runs = MovementDetector.runs(from: samples, until: TestClock.date("2026-10-15 09:00"), parameters: medium)
        XCTAssertEqual(runs, [
            makeRun(.stationary, "2026-10-15 07:00", "2026-10-15 08:00"),
            makeRun(.walking, "2026-10-15 08:00", "2026-10-15 08:10"),
            makeRun(.automotive, "2026-10-15 08:10", "2026-10-15 08:40"),
            makeRun(.stationary, "2026-10-15 08:40", "2026-10-15 09:00", ongoing: true),
        ])
    }

    func testLowConfidenceAloneDoesNotChangeTheActivity() {
        let samples = [
            makeSample("2026-10-15 07:00", .stationary),
            makeSample("2026-10-15 07:30", .walking, .low),
            makeSample("2026-10-15 07:40", .unknown, .high),
        ]
        let runs = MovementDetector.runs(from: samples, until: TestClock.date("2026-10-15 08:00"), parameters: medium)
        XCTAssertEqual(runs, [makeRun(.stationary, "2026-10-15 07:00", "2026-10-15 08:00", ongoing: true)])
    }

    func testConfirmedChangeStartsAtTheFirstLowConfidenceSample() {
        let samples = [
            makeSample("2026-10-15 08:00", .walking),
            makeSample("2026-10-15 08:10", .automotive, .low),
            makeSample("2026-10-15 08:12", .automotive, .medium),
        ]
        let runs = MovementDetector.runs(from: samples, until: TestClock.date("2026-10-15 08:30"), parameters: medium)
        XCTAssertEqual(runs, [
            makeRun(.walking, "2026-10-15 08:00", "2026-10-15 08:10"),
            makeRun(.automotive, "2026-10-15 08:10", "2026-10-15 08:30", ongoing: true),
        ])
    }

    func testShortBlipsAreAbsorbed() {
        let samples = [
            makeSample("2026-10-15 08:00", .automotive),
            makeSample("2026-10-15 08:10:00", .walking),
            makeSample("2026-10-15 08:10:40", .automotive),
            makeSample("2026-10-15 08:30", .stationary),
        ]
        let runs = MovementDetector.runs(from: samples, until: TestClock.date("2026-10-15 09:00"), parameters: medium)
        XCTAssertEqual(runs, [
            makeRun(.automotive, "2026-10-15 08:00", "2026-10-15 08:30"),
            makeRun(.stationary, "2026-10-15 08:30", "2026-10-15 09:00", ongoing: true),
        ])
    }

    func testEpisodesBridgeShortPauses() {
        let runs = [
            makeRun(.stationary, "2026-10-15 07:00", "2026-10-15 08:00"),
            makeRun(.walking, "2026-10-15 08:00", "2026-10-15 08:05"),
            makeRun(.stationary, "2026-10-15 08:05", "2026-10-15 08:08"),
            makeRun(.automotive, "2026-10-15 08:08", "2026-10-15 08:30"),
            makeRun(.walking, "2026-10-15 08:30", "2026-10-15 08:35"),
            makeRun(.stationary, "2026-10-15 08:35", "2026-10-15 09:00", ongoing: true),
        ]
        let episodes = MovementDetector.episodes(from: runs, parameters: medium)
        XCTAssertEqual(episodes.count, 1)
        XCTAssertEqual(episodes[0].start, TestClock.date("2026-10-15 08:00"))
        XCTAssertEqual(episodes[0].end, TestClock.date("2026-10-15 08:35"))
        XCTAssertFalse(episodes[0].isOngoing)
        XCTAssertEqual(episodes[0].dominantActivity, .automotive)
    }

    func testLongPauseSplitsEpisodes() {
        let runs = [
            makeRun(.walking, "2026-10-15 08:00", "2026-10-15 08:10"),
            makeRun(.stationary, "2026-10-15 08:10", "2026-10-15 08:30"),
            makeRun(.cycling, "2026-10-15 08:30", "2026-10-15 08:50", ongoing: true),
        ]
        let episodes = MovementDetector.episodes(from: runs, parameters: medium)
        XCTAssertEqual(episodes.map(\.start), [TestClock.date("2026-10-15 08:00"), TestClock.date("2026-10-15 08:30")])
        XCTAssertEqual(episodes.map(\.isOngoing), [false, true])
        XCTAssertEqual(episodes[1].dominantActivity, .cycling)
    }

    func testBriefStopAtTheEndKeepsTheEpisodeOngoing() {
        let runs = [
            makeRun(.automotive, "2026-10-15 08:00", "2026-10-15 08:20"),
            makeRun(.stationary, "2026-10-15 08:20", "2026-10-15 08:22", ongoing: true),
        ]
        let episodes = MovementDetector.episodes(from: runs, parameters: medium)
        XCTAssertEqual(episodes.count, 1)
        XCTAssertTrue(episodes[0].isOngoing)
        XCTAssertEqual(episodes[0].end, TestClock.date("2026-10-15 08:20"))
    }
}

final class SuggestionBuilderTests: XCTestCase {
    private let now = TestClock.date("2026-10-15 12:00")
    private var day: DateInterval { TestClock.calendar.dayInterval(containing: now) }

    func testLoggedTimeIsSubtracted() {
        let runs = [makeRun(.walking, "2026-10-15 08:00:20", "2026-10-15 08:40:50")]
        let book = SegmentBook(segments: [makeSegment(.walking, "2026-10-15 08:10", "2026-10-15 08:30")])
        let suggestions = SuggestionBuilder.suggestions(runs: runs, book: book, within: day, dismissed: [], includeStationary: true, now: now)
        XCTAssertEqual(suggestions, [
            Suggestion(start: TestClock.date("2026-10-15 08:00"), end: TestClock.date("2026-10-15 08:10"), activity: .walking, isOngoing: false),
            Suggestion(start: TestClock.date("2026-10-15 08:30"), end: TestClock.date("2026-10-15 08:40"), activity: .walking, isOngoing: false),
        ])
    }

    func testDismissedAndTooShortSuggestionsAreHidden() {
        let runs = [
            makeRun(.walking, "2026-10-15 08:00", "2026-10-15 08:02"),
            makeRun(.cycling, "2026-10-15 09:00", "2026-10-15 09:30"),
            makeRun(.automotive, "2026-10-15 10:00", "2026-10-15 10:30"),
        ]
        let dismissed: Set<String> = [Suggestion(start: TestClock.date("2026-10-15 09:00"), end: TestClock.date("2026-10-15 09:30"), activity: .cycling, isOngoing: false).id]
        let suggestions = SuggestionBuilder.suggestions(runs: runs, book: SegmentBook(), within: day, dismissed: dismissed, includeStationary: true, now: now)
        XCTAssertEqual(suggestions.map(\.activity), [.automotive])
    }

    func testStationarySuggestionsAreOptional() {
        let runs = [makeRun(.stationary, "2026-10-14 22:00", "2026-10-15 07:00")]
        let without = SuggestionBuilder.suggestions(runs: runs, book: SegmentBook(), within: day, dismissed: [], includeStationary: false, now: now)
        XCTAssertTrue(without.isEmpty)

        let with = SuggestionBuilder.suggestions(runs: runs, book: SegmentBook(), within: day, dismissed: [], includeStationary: true, now: now)
        XCTAssertEqual(with.map(\.start), [TestClock.date("2026-10-15 00:00")], "Clipped to the day")
    }

    func testOnlyRunsReachingNowAreOngoing() {
        let current = makeRun(.walking, "2026-10-15 11:40", "2026-10-15 12:00", ongoing: true)
        let suggestions = SuggestionBuilder.suggestions(runs: [current], book: SegmentBook(), within: day, dismissed: [], includeStationary: true, now: now)
        XCTAssertEqual(suggestions.map(\.isOngoing), [true])

        // A past day's last run is cut at midnight; it is not ongoing.
        let yesterday = TestClock.calendar.dayInterval(containing: TestClock.date("2026-10-14 12:00"))
        let cut = makeRun(.walking, "2026-10-14 23:40", "2026-10-15 00:00", ongoing: true)
        let old = SuggestionBuilder.suggestions(runs: [cut], book: SegmentBook(), within: yesterday, dismissed: [], includeStationary: true, now: now)
        XCTAssertEqual(old.map(\.isOngoing), [false])
    }
}
