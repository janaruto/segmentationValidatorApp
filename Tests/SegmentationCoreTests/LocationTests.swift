import Foundation
import XCTest
@testable import SegmentationCore

/// A point `north` and `east` meters away from a fixed place in Zurich.
private func point(_ time: String, north: Double = 0, east: Double = 0, accuracy: Double = 10) -> LocationPoint {
    let latitude = 47.3925
    let longitude = 8.5235
    return LocationPoint(
        timestamp: TestClock.date(time),
        latitude: latitude + north / 111_195,
        longitude: longitude + east / (111_195 * cos(latitude * .pi / 180)),
        accuracy: accuracy
    )
}

final class GeoMathTests: XCTestCase {
    func testDistance() {
        let a = point("2026-10-15 08:00")
        let b = point("2026-10-15 08:05", north: 400)
        XCTAssertEqual(a.distance(to: b), 400, accuracy: 1)
        let c = point("2026-10-15 08:05", east: 150)
        XCTAssertEqual(a.distance(to: c), 150, accuracy: 1)
        XCTAssertEqual(a.distance(to: a), 0, accuracy: 0.001)

        // Zurich main station to Bern main station: about 95.5 km as the crow flies.
        XCTAssertEqual(GeoMath.distance(47.3779, 8.5403, 46.9490, 7.4392), 95_500, accuracy: 1_000)
    }

    func testTravelledDistanceIgnoresGPSNoise() {
        let sitting = [
            point("2026-10-15 08:00"),
            point("2026-10-15 08:05", north: 8),
            point("2026-10-15 08:10", east: 12),
        ]
        XCTAssertEqual(GeoMath.travelledDistance(along: sitting), 0)

        let walk = sitting + [point("2026-10-15 08:15", east: 412), point("2026-10-15 08:20", east: 812)]
        XCTAssertEqual(GeoMath.travelledDistance(along: walk), 800, accuracy: 2)
    }
}

final class LocationPromptEngineTests: XCTestCase {
    private let calendar = TestClock.calendar

    private struct Run {
        var prompts: [LocationPrompt?]
        var state: LocationPromptState
    }

    private func run(
        _ points: [LocationPoint],
        running: Segment?,
        state: LocationPromptState = LocationPromptState(),
        settings: DetectionSettings = DetectionSettings()
    ) -> Run {
        var state = state
        var prompts: [LocationPrompt?] = []
        for point in points {
            let result = LocationPromptEngine.evaluate(point: point, running: running, state: state, settings: settings, calendar: calendar)
            prompts.append(result.prompt)
            state = result.state
        }
        return Run(prompts: prompts, state: state)
    }

    func testAsksOnceWhenFarFromThePreviousPoint() {
        let home = makeSegment(.stationary, "2026-10-15 07:00", nil)
        let result = run([
            point("2026-10-15 09:00"),
            point("2026-10-15 09:05", north: 20),
            point("2026-10-15 09:10", east: 30),
            point("2026-10-15 09:15", north: 650),
            point("2026-10-15 09:20", north: 1500),
        ], running: home)

        XCTAssertNil(result.prompts[0])
        XCTAssertNil(result.prompts[1])
        XCTAssertNil(result.prompts[2])
        let prompt = result.prompts[3]
        XCTAssertEqual(prompt?.kind, .moving)
        XCTAssertEqual(prompt?.since, TestClock.date("2026-10-15 09:10"), "Last time the user was still at home")
        XCTAssertEqual(prompt?.askedAt, TestClock.date("2026-10-15 09:15"))
        XCTAssertEqual(prompt?.segmentID, home.id)
        XCTAssertEqual(prompt?.distance ?? 0, 650, accuracy: 35)
        XCTAssertNil(result.prompts[4], "Asked only once per movement")
        XCTAssertEqual(result.state.pending, prompt)
    }

    func testSmallMovementsAndGPSNoiseDoNotAsk() {
        let result = run([
            point("2026-10-15 09:00"),
            point("2026-10-15 09:05", north: 60),
            point("2026-10-15 09:10", north: -40, east: 70),
            point("2026-10-15 09:15", east: 300),
            point("2026-10-15 09:20", east: 120),
        ], running: makeSegment(.stationary, "2026-10-15 07:00", nil))
        XCTAssertTrue(result.prompts.allSatisfy { $0 == nil })
    }

    func testSlowWalkIsNoticedFromThePlaceWhereTheUserStayed() {
        let result = run([
            point("2026-10-15 09:00"),
            point("2026-10-15 09:05"),
            point("2026-10-15 09:10", north: 250),
            point("2026-10-15 09:15", north: 500),
        ], running: nil)
        XCTAssertNil(result.prompts[2], "250 m is not enough")
        XCTAssertEqual(result.prompts[3]?.kind, .moving, "500 m from home, although only 250 m from the previous point")
        XCTAssertEqual(result.prompts[3]?.since, TestClock.date("2026-10-15 09:05"))
        XCTAssertNil(result.prompts[3]?.segmentID)
    }

    func testAsksAgainWhenLeavingTheNextPlace() {
        let home = makeSegment(.stationary, "2026-10-15 07:00", nil)
        let result = run([
            point("2026-10-15 09:00"),
            point("2026-10-15 09:05", north: 900),      // asked
            point("2026-10-15 09:10", north: 2000),
            point("2026-10-15 09:15", north: 2030),     // stays here: new reference
            point("2026-10-15 10:30", north: 2010),
            point("2026-10-15 10:35", north: 2900),     // leaves again
        ], running: home)
        XCTAssertEqual(result.prompts.map { $0?.kind }, [nil, .moving, nil, nil, nil, .moving])
        XCTAssertEqual(result.prompts[5]?.since, TestClock.date("2026-10-15 10:30"))
    }

    func testShortStopDuringATripKeepsTheOriginalStart() {
        let result = run([
            point("2026-10-15 09:00"),
            point("2026-10-15 09:05"),
            point("2026-10-15 09:10", north: 900),      // asked, not answered
            point("2026-10-15 09:15", north: 2000),
            point("2026-10-15 09:20", north: 2050),     // traffic jam
            point("2026-10-15 09:25", north: 4000),     // moving again
        ], running: nil)
        XCTAssertEqual(result.prompts.map { $0?.kind }, [nil, nil, .moving, nil, nil, .moving])
        XCTAssertEqual(result.prompts[5]?.since, TestClock.date("2026-10-15 09:05"), "Same trip as the first question")
    }

    func testInaccuratePointsAreNotCompared() {
        let result = run([
            point("2026-10-15 09:00"),
            point("2026-10-15 09:05", north: 2000, accuracy: 1500),
        ], running: nil)
        XCTAssertNil(result.prompts[1])
        XCTAssertEqual(result.state.previous?.timestamp, TestClock.date("2026-10-15 09:00"))
        XCTAssertEqual(result.state.latest?.timestamp, TestClock.date("2026-10-15 09:05"))
    }

    func testAsksStationaryWhenHardlyMovingDuringAMovingSegment() {
        let walk = makeSegment(.walking, "2026-10-15 09:00", nil)
        let result = run([
            point("2026-10-15 09:02"),
            point("2026-10-15 09:07", north: 400),
            point("2026-10-15 09:12", north: 800),
            point("2026-10-15 09:17", north: 850),      // hardly moved: stationary?
            point("2026-10-15 09:22", north: 860),
            point("2026-10-15 09:27", north: 1500),     // moves on
            point("2026-10-15 09:32", north: 1520),     // stops again
        ], running: walk)
        XCTAssertEqual(result.prompts.map { $0?.kind }, [nil, nil, nil, .stationary, nil, nil, .stationary])
        XCTAssertEqual(result.prompts[3]?.since, TestClock.date("2026-10-15 09:12"), "Arrived at or before the first close point")
        XCTAssertEqual(result.prompts[3]?.segmentID, walk.id)
        XCTAssertEqual(result.prompts[6]?.since, TestClock.date("2026-10-15 09:27"))
    }

    func testStationaryNeedsAWholeIntervalOfTheSegment() {
        let tram = makeSegment(.busTram, "2026-10-15 09:10", nil)
        let result = run([
            point("2026-10-15 09:07"),
            point("2026-10-15 09:12", north: 20),       // the previous point is from before the segment
            point("2026-10-15 09:17", north: 30),
        ], running: tram)
        XCTAssertEqual(result.prompts.map { $0?.kind }, [nil, nil, .stationary])
        XCTAssertEqual(result.prompts[2]?.since, TestClock.date("2026-10-15 09:12"))
    }

    func testANewSegmentStartsAFreshComparison() {
        let home = makeSegment(.stationary, "2026-10-15 07:00", nil)
        let first = run([point("2026-10-15 08:00"), point("2026-10-15 08:05")], running: home)

        // The user logged the trip and arrived at work, where a new stationary segment runs.
        let work = makeSegment(.stationary, "2026-10-15 08:40", nil)
        let second = run([
            point("2026-10-15 08:45", north: 5000),
            point("2026-10-15 08:50", north: 5010),
        ], running: work, state: first.state)
        XCTAssertTrue(second.prompts.allSatisfy { $0 == nil })
        XCTAssertEqual(second.state.segmentID, work.id)
        XCTAssertEqual(second.state.anchor?.timestamp, TestClock.date("2026-10-15 08:45"))
    }

    func testNoQuestionsDuringQuietHoursOrWhenTurnedOff() {
        let quiet = run([
            point("2026-10-15 22:30"),
            point("2026-10-15 22:35", north: 3000),
        ], running: nil)
        XCTAssertTrue(quiet.prompts.allSatisfy { $0 == nil })
        XCTAssertFalse(quiet.state.movingAsked, "Asked later when quiet hours are over")

        var settings = DetectionSettings()
        settings.locationPrompts = false
        let off = run([
            point("2026-10-15 09:00"),
            point("2026-10-15 09:05", north: 3000),
        ], running: nil, settings: settings)
        XCTAssertTrue(off.prompts.allSatisfy { $0 == nil })
    }

    func testCustomDistances() {
        var settings = DetectionSettings()
        settings.movingDistance = 1000
        let result = run([
            point("2026-10-15 09:00"),
            point("2026-10-15 09:05", north: 700),
            point("2026-10-15 09:10", north: 1400),
        ], running: nil, settings: settings)
        XCTAssertEqual(result.prompts.map { $0?.kind }, [nil, nil, .moving])
    }

    func testDepartureFromTheMotionSensor() {
        let prompt = LocationPrompt(
            id: UUID(),
            kind: .moving,
            askedAt: TestClock.date("2026-10-15 09:15"),
            since: TestClock.date("2026-10-15 09:10"),
            distance: 650,
            segmentID: nil
        )
        let runs = [
            makeRun(.stationary, "2026-10-15 08:00", "2026-10-15 09:12"),
            makeRun(.walking, "2026-10-15 09:12", "2026-10-15 09:15", ongoing: true),
        ]
        let departure = LocationPromptEngine.departure(for: prompt, runs: runs)
        XCTAssertEqual(departure?.start, TestClock.date("2026-10-15 09:12"))
        XCTAssertEqual(departure?.activity, .walking)

        let earlier = [makeRun(.walking, "2026-10-15 09:05", "2026-10-15 09:15", ongoing: true)]
        XCTAssertEqual(LocationPromptEngine.departure(for: prompt, runs: earlier)?.start, prompt.since, "Never before the user was last seen at home")
        XCTAssertNil(LocationPromptEngine.departure(for: prompt, runs: [makeRun(.stationary, "2026-10-15 08:00", "2026-10-15 09:15")]))
    }

    func testNotificationPayloadRoundTrip() {
        let prompt = LocationPrompt(
            id: UUID(),
            kind: .stationary,
            askedAt: TestClock.date("2026-10-15 09:17:42"),
            since: TestClock.date("2026-10-15 09:12:03"),
            distance: 48.5,
            segmentID: UUID()
        )
        XCTAssertEqual(ReminderPayload.notification(from: ReminderPayload.userInfo(for: prompt) as [AnyHashable: Any]), .location(prompt))

        var withoutSegment = prompt
        withoutSegment.segmentID = nil
        XCTAssertEqual(ReminderPayload.notification(from: ReminderPayload.userInfo(for: withoutSegment) as [AnyHashable: Any]), .location(withoutSegment))
    }

    func testStateSurvivesEncoding() throws {
        let result = run([point("2026-10-15 09:00"), point("2026-10-15 09:05", north: 900)], running: nil)
        let data = try JSONEncoder().encode(result.state)
        XCTAssertEqual(try JSONDecoder().decode(LocationPromptState.self, from: data), result.state)
        XCTAssertEqual(try JSONDecoder().decode(LocationPromptState.self, from: Data("{}".utf8)), LocationPromptState())
    }
}

final class LocationSettingsTests: XCTestCase {
    func testDefaultsAndLenientDecoding() throws {
        let defaults = try JSONDecoder().decode(DetectionSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(defaults.locationTracking)
        XCTAssertEqual(defaults.locationInterval, 5)
        XCTAssertTrue(defaults.locationPrompts)
        XCTAssertEqual(defaults.movingDistance, 400)
        XCTAssertEqual(defaults.stationaryDistance, 150)

        let odd = try JSONDecoder().decode(
            DetectionSettings.self,
            from: Data(#"{"locationTracking": true, "locationInterval": 0, "movingDistance": "far", "stationaryDistance": 1}"#.utf8)
        )
        XCTAssertTrue(odd.locationTracking)
        XCTAssertEqual(odd.locationInterval, 1)
        XCTAssertEqual(odd.movingDistance, 400)
        XCTAssertEqual(odd.stationaryDistance, 20)
    }
}

final class LocationStoreTests: XCTestCase {
    private var folder: URL!
    private let calendar = TestClock.calendar

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("LocationStoreTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testSavesOneFilePerDay() throws {
        let store = LocationPointStore(folder: folder)
        let day = TestClock.date("2026-10-15 00:00")
        var answered = point("2026-10-15 09:05", north: 900)
        answered.prompt = .moving
        answered.answer = true
        let points = [answered, point("2026-10-15 09:00")]
        try store.save(points, day: day, calendar: calendar)
        try store.save([point("2026-10-16 07:00")], day: TestClock.date("2026-10-16 00:00"), calendar: calendar)

        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("2026-10-15.json").path))
        let loaded = try store.load(day: day, calendar: calendar)
        XCTAssertEqual(loaded, points.sorted { $0.timestamp < $1.timestamp })
        XCTAssertEqual(loaded.last?.answer, true)

        XCTAssertEqual(store.storedDays(calendar: calendar), [day, TestClock.date("2026-10-16 00:00")])
        let range = store.points(from: TestClock.date("2026-10-15 09:01"), to: TestClock.date("2026-10-16 23:59"), calendar: calendar)
        XCTAssertEqual(range.map(\.timestamp), [TestClock.date("2026-10-15 09:05"), TestClock.date("2026-10-16 07:00")])

        XCTAssertEqual(try store.load(day: TestClock.date("2026-10-17 00:00"), calendar: calendar), [])
        try store.save([], day: day, calendar: calendar)
        XCTAssertEqual(store.storedDays(calendar: calendar), [TestClock.date("2026-10-16 00:00")])

        try store.deleteAll()
        XCTAssertEqual(store.storedDays(calendar: calendar), [])
    }

    func testDamagedFileIsMovedAside() throws {
        let store = LocationPointStore(folder: folder)
        let day = TestClock.date("2026-10-15 00:00")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.url(for: day, calendar: calendar))
        XCTAssertThrowsError(try store.load(day: day, calendar: calendar))
        XCTAssertNotNil(store.quarantine(day: day, calendar: calendar))
        XCTAssertEqual(try store.load(day: day, calendar: calendar), [])
        XCTAssertEqual(store.storedDays(calendar: calendar), [], "The copy is kept but not read as a day")
    }
}

final class LocationCSVTests: XCTestCase {
    func testOneRowPerPointWithTheLoggedType() {
        var book = SegmentBook()
        book.insert(makeSegment(.stationary, "2026-10-15 07:00", "2026-10-15 09:12"))
        book.insert(makeSegment(.walking, "2026-10-15 09:12", nil))
        var asked = point("2026-10-15 09:15", north: 650, accuracy: 8.26)
        asked.prompt = .moving
        asked.answer = true
        asked.speed = 1.4
        let points = [asked, point("2026-10-15 09:10")]

        let csv = LocationCSVExport.csv(
            for: points,
            book: book,
            options: CSVOptions(),
            timeZone: TestClock.timeZone,
            now: TestClock.date("2026-10-15 09:20")
        )
        let rows = CSVParser.rows(from: csv)
        XCTAssertEqual(rows.first, LocationCSVExport.columns)
        XCTAssertEqual(rows.count, 3)

        func value(_ row: Int, _ column: String) -> String {
            rows[row][LocationCSVExport.columns.firstIndex(of: column)!]
        }
        XCTAssertEqual(value(1, "date"), "2026-10-15")
        XCTAssertEqual(value(1, "time"), "09:10:00")
        XCTAssertEqual(value(1, "timestamp_iso"), "2026-10-15T09:10:00+02:00")
        XCTAssertEqual(value(1, "latitude"), "47.392500")
        XCTAssertEqual(value(1, "movement_type"), "stationary")
        XCTAssertEqual(value(1, "distance_m"), "")
        XCTAssertEqual(value(1, "prompt"), "")
        XCTAssertEqual(value(1, "answer"), "")
        XCTAssertEqual(value(2, "movement_type"), "walking", "The running segment counts until now")
        XCTAssertEqual(value(2, "distance_m"), "650")
        XCTAssertEqual(value(2, "accuracy_m"), "8.3")
        XCTAssertEqual(value(2, "speed_mps"), "1.40")
        XCTAssertEqual(value(2, "altitude_m"), "")
        XCTAssertEqual(value(2, "trigger"), "interval")
        XCTAssertEqual(value(2, "prompt"), "moving")
        XCTAssertEqual(value(2, "answer"), "true")
        XCTAssertEqual(value(2, "id"), asked.id.uuidString.lowercased())

        let semicolon = LocationCSVExport.csv(
            for: points,
            book: book,
            options: CSVOptions(delimiter: .semicolon),
            timeZone: TestClock.timeZone,
            now: TestClock.date("2026-10-15 09:20")
        )
        XCTAssertTrue(semicolon.hasPrefix("date;time;"))
        XCTAssertTrue(semicolon.contains(";47.392500;"), "Decimal point, also with semicolons")
    }

    func testFileName() {
        let zone = TestClock.timeZone
        XCTAssertEqual(LocationCSVExport.fileName(first: nil, last: nil, timeZone: zone), "locations.csv")
        XCTAssertEqual(
            LocationCSVExport.fileName(first: TestClock.date("2026-10-01 08:00"), last: TestClock.date("2026-10-15 08:00"), timeZone: zone),
            "locations_2026-10-01_to_2026-10-15.csv"
        )
    }
}

final class SegmentAtTimeTests: XCTestCase {
    func testFindsTheSegmentAtATime() {
        var book = SegmentBook()
        let night = makeSegment(.stationary, "2026-10-14 22:00", "2026-10-15 07:30")
        let walk = makeSegment(.walking, "2026-10-15 07:30", "2026-10-15 07:45")
        let tram = makeSegment(.busTram, "2026-10-15 07:50", nil)
        for segment in [tram, night, walk] {
            book.insert(segment)
        }
        let now = TestClock.date("2026-10-15 08:30")
        XCTAssertEqual(book.segment(at: TestClock.date("2026-10-15 03:00"), now: now), night)
        XCTAssertEqual(book.segment(at: TestClock.date("2026-10-15 07:30"), now: now), walk, "A segment starts where the previous one ends")
        XCTAssertNil(book.segment(at: TestClock.date("2026-10-15 07:47"), now: now), "Gap")
        XCTAssertEqual(book.segment(at: TestClock.date("2026-10-15 08:29"), now: now), tram)
        XCTAssertNil(book.segment(at: TestClock.date("2026-10-15 08:31"), now: now), "The running segment ends now")
        XCTAssertNil(book.segment(at: TestClock.date("2026-10-14 21:00"), now: now))
    }
}
