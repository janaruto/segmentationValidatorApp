import XCTest
@testable import SegmentationCore

final class ReminderEngineTests: XCTestCase {
    private let calendar = TestClock.calendar

    private func episode(_ activity: DetectedActivity, _ start: String, _ end: String, ongoing: Bool = false) -> MovementEpisode {
        MovementEpisode(
            start: TestClock.date(start),
            end: TestClock.date(end),
            isOngoing: ongoing,
            runs: [makeRun(activity, start, end, ongoing: ongoing)]
        )
    }

    private func evaluate(
        _ episodes: [MovementEpisode],
        book: SegmentBook = SegmentBook(),
        state: ReminderState = ReminderState(),
        settings: DetectionSettings = DetectionSettings(),
        at now: String
    ) -> ReminderEngine.Result {
        ReminderEngine.evaluate(episodes: episodes, book: book, state: state, settings: settings, now: TestClock.date(now), calendar: calendar)
    }

    func testRemindsOnceForAnOngoingMovement() {
        let walk = episode(.walking, "2026-10-15 08:10", "2026-10-15 08:30", ongoing: true)
        let first = evaluate([walk], at: "2026-10-15 08:30")
        XCTAssertEqual(first.outcome, .sent)
        XCTAssertEqual(first.reminder, Reminder(start: TestClock.date("2026-10-15 08:10"), end: nil, activity: .walking))

        let longer = episode(.walking, "2026-10-15 08:10", "2026-10-15 09:10", ongoing: true)
        let second = evaluate([longer], state: first.state, at: "2026-10-15 09:10")
        XCTAssertEqual(second.outcome, .alreadyHandled)
        XCTAssertNil(second.reminder)
    }

    func testShortAndOldMovementsDoNotTrigger() {
        let short = episode(.walking, "2026-10-15 08:26", "2026-10-15 08:30", ongoing: true)
        XCTAssertEqual(evaluate([short], at: "2026-10-15 08:30").outcome, .noMovement)

        let old = episode(.automotive, "2026-10-15 03:00", "2026-10-15 04:00")
        XCTAssertEqual(evaluate([old], at: "2026-10-15 08:30").outcome, .noMovement)
    }

    func testAlreadyLoggedMovementsDoNotTrigger() {
        var book = SegmentBook()
        book.startLive(.walking, at: TestClock.date("2026-10-15 08:11"))
        let walk = episode(.walking, "2026-10-15 08:10", "2026-10-15 08:30", ongoing: true)
        let result = evaluate([walk], book: book, at: "2026-10-15 08:30")
        XCTAssertEqual(result.outcome, .alreadyHandled)
        XCTAssertNil(result.reminder)
    }

    func testQuietHoursAndCooldownPostponeReminders() {
        let late = episode(.walking, "2026-10-15 22:50", "2026-10-15 23:15", ongoing: true)
        let quiet = evaluate([late], at: "2026-10-15 23:15")
        XCTAssertEqual(quiet.outcome, .quietHours)
        XCTAssertTrue(quiet.state.startHandled.isEmpty, "Postponed, not forgotten")

        let walk = episode(.walking, "2026-10-15 08:10", "2026-10-15 08:30", ongoing: true)
        var state = ReminderState()
        state.lastReminderAt = TestClock.date("2026-10-15 08:20")
        let cooling = evaluate([walk], state: state, at: "2026-10-15 08:30")
        XCTAssertEqual(cooling.outcome, .coolingDown)

        let later = evaluate([walk], state: cooling.state, at: "2026-10-15 08:41")
        XCTAssertEqual(later.outcome, .sent)
    }

    func testQuietTimeWrapsAroundMidnight() {
        let settings = DetectionSettings()
        XCTAssertTrue(ReminderEngine.isQuietTime(TestClock.date("2026-10-15 06:59"), settings: settings, calendar: calendar))
        XCTAssertFalse(ReminderEngine.isQuietTime(TestClock.date("2026-10-15 07:00"), settings: settings, calendar: calendar))
        XCTAssertFalse(ReminderEngine.isQuietTime(TestClock.date("2026-10-15 21:59"), settings: settings, calendar: calendar))
        XCTAssertTrue(ReminderEngine.isQuietTime(TestClock.date("2026-10-15 22:00"), settings: settings, calendar: calendar))

        var lunch = DetectionSettings()
        lunch.quietHoursStart = 12 * 60
        lunch.quietHoursEnd = 13 * 60
        XCTAssertTrue(ReminderEngine.isQuietTime(TestClock.date("2026-10-15 12:30"), settings: lunch, calendar: calendar))
        XCTAssertFalse(ReminderEngine.isQuietTime(TestClock.date("2026-10-15 13:30"), settings: lunch, calendar: calendar))

        lunch.quietHoursEnabled = false
        XCTAssertFalse(ReminderEngine.isQuietTime(TestClock.date("2026-10-15 12:30"), settings: lunch, calendar: calendar))
    }

    func testEndTimingWaitsUntilTheMovementIsOver() {
        var settings = DetectionSettings()
        settings.timing = .end
        let ongoing = episode(.automotive, "2026-10-15 08:10", "2026-10-15 08:30", ongoing: true)
        XCTAssertEqual(evaluate([ongoing], settings: settings, at: "2026-10-15 08:30").outcome, .alreadyHandled)

        let finished = episode(.automotive, "2026-10-15 08:10", "2026-10-15 08:30")
        let result = evaluate([finished], settings: settings, at: "2026-10-15 08:40")
        XCTAssertEqual(result.outcome, .sent)
        XCTAssertEqual(result.reminder?.end, TestClock.date("2026-10-15 08:30"))
    }

    func testBothTimingsRemindAtStartAndEnd() {
        var settings = DetectionSettings()
        settings.timing = .both
        let ongoing = episode(.cycling, "2026-10-15 08:00", "2026-10-15 08:10", ongoing: true)
        let start = evaluate([ongoing], settings: settings, at: "2026-10-15 08:10")
        XCTAssertEqual(start.outcome, .sent)
        XCTAssertNil(start.reminder?.end)

        let finished = episode(.cycling, "2026-10-15 08:00", "2026-10-15 08:45")
        let end = evaluate([finished], state: start.state, settings: settings, at: "2026-10-15 08:50")
        XCTAssertEqual(end.outcome, .sent)
        XCTAssertEqual(end.reminder?.end, TestClock.date("2026-10-15 08:45"))

        let again = evaluate([finished], state: end.state, settings: settings, at: "2026-10-15 09:30")
        XCTAssertEqual(again.outcome, .alreadyHandled)
    }

    func testOlderUnloggedMovementsAreSummarised() {
        let walk = episode(.walking, "2026-10-15 07:00", "2026-10-15 07:20")
        let drive = episode(.automotive, "2026-10-15 08:00", "2026-10-15 08:30")
        let result = evaluate([walk, drive], at: "2026-10-15 08:40")
        XCTAssertEqual(result.reminder?.activity, .automotive)
        XCTAssertEqual(result.reminder?.additionalUnlogged, 1)

        let next = evaluate([walk, drive], state: result.state, at: "2026-10-15 09:30")
        XCTAssertEqual(next.outcome, .alreadyHandled)
    }

    func testDisabledRemindersNeverFire() {
        var settings = DetectionSettings()
        settings.remindersEnabled = false
        let walk = episode(.walking, "2026-10-15 08:10", "2026-10-15 08:30", ongoing: true)
        XCTAssertEqual(evaluate([walk], settings: settings, at: "2026-10-15 08:30").outcome, .disabled)
    }

    func testNotificationPayloadRoundTrip() {
        let reminder = Reminder(
            start: TestClock.date("2026-10-15 08:10"),
            end: TestClock.date("2026-10-15 08:40"),
            activity: .automotive,
            additionalUnlogged: 2
        )
        let userInfo = ReminderPayload.userInfo(for: reminder) as [AnyHashable: Any]
        XCTAssertEqual(ReminderPayload.reminder(from: userInfo), reminder)
        XCTAssertNil(ReminderPayload.reminder(from: ["kind": "something-else"]))
    }

    func testSettingsDecodeLeniently() throws {
        let json = Data(#"{"sensitivity":"high","timing":"nonsense","quietHoursStart":60}"#.utf8)
        let settings = try JSONDecoder().decode(DetectionSettings.self, from: json)
        XCTAssertEqual(settings.sensitivity, .high)
        XCTAssertEqual(settings.timing, .start)
        XCTAssertEqual(settings.quietHoursStart, 60)
        XCTAssertTrue(settings.remindersEnabled)
    }
}
