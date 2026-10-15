import XCTest
@testable import SegmentationCore

final class CSVTests: XCTestCase {
    private let zone = TestClock.timeZone

    private func lines(_ csv: String) -> [String] {
        csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
    }

    func testExportWritesHeaderAndReadableRows() {
        var walk = makeSegment(.walking, "2026-10-15 08:12", "2026-10-15 08:40", note: "to the station")
        walk.id = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00CF4FC964FF")!
        let csv = CSVExport.csv(for: [walk], options: CSVOptions(), timeZone: zone)

        XCTAssertEqual(lines(csv), [
            "date,start_time,end_time,duration_min,movement_type,note,start_iso,end_iso,timezone,source,detected_activity,id,created_at,updated_at",
            "2026-10-15,08:12,08:40,28,walking,to the station,2026-10-15T08:12:00+02:00,2026-10-15T08:40:00+02:00,Europe/Zurich,manual,,6f9619ff-8b86-d011-b42d-00cf4fc964ff,2026-10-15T08:12:00+02:00,2026-10-15T08:12:00+02:00",
        ])
        XCTAssertTrue(csv.hasSuffix("\r\n"))
    }

    func testFieldsAreEscaped() {
        XCTAssertEqual(CSVExport.escape("plain", delimiter: .comma), "plain")
        XCTAssertEqual(CSVExport.escape("a,b", delimiter: .comma), "\"a,b\"")
        XCTAssertEqual(CSVExport.escape("a,b", delimiter: .semicolon), "a,b")
        XCTAssertEqual(CSVExport.escape("a;b", delimiter: .semicolon), "\"a;b\"")
        XCTAssertEqual(CSVExport.escape("say \"hi\"", delimiter: .comma), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(CSVExport.escape("two\r\nlines", delimiter: .comma), "\"two\r\nlines\"")
        XCTAssertEqual(CSVExport.escape(" padded", delimiter: .comma), "\" padded\"")
    }

    func testSemicolonBOMAndRunningOptions() {
        let running = Segment(start: TestClock.date("2026-10-15 09:00"), end: nil, type: .busTram)
        let closed = makeSegment(.bike, "2026-10-15 08:00", "2026-10-15 08:30")
        var options = CSVOptions()
        options.delimiter = .semicolon
        options.includeBOM = true
        options.includeRunning = false

        let data = CSVExport.data(for: [running, closed], options: options, timeZone: zone)
        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF])
        let text = String(decoding: data.dropFirst(3), as: UTF8.self)
        let rows = lines(text)
        XCTAssertEqual(rows.count, 2, "Header plus the closed segment")
        XCTAssertTrue(rows[0].hasPrefix("date;start_time;end_time;"))
        XCTAssertTrue(rows[1].hasPrefix("2026-10-15;08:00;08:30;30;bike;"))

        options.includeRunning = true
        let withRunning = lines(CSVExport.csv(for: [running, closed], options: options, timeZone: zone))
        XCTAssertEqual(withRunning.count, 3)
        XCTAssertTrue(withRunning[2].hasPrefix("2026-10-15;09:00;;;bus/tram;"), "Running segments have no end yet")
    }

    func testExportImportRoundTrip() throws {
        var night = makeSegment(.stationary, "2026-10-14 22:30", "2026-10-15 06:45", note: "home, \"sweet\" home\nsecond line")
        night.detectedActivity = .stationary
        night.source = .suggestion
        let tram = makeSegment(.busTram, "2026-10-15 07:00", "2026-10-15 07:25", source: .reminder)
        let running = Segment(start: TestClock.date("2026-10-15 07:25"), end: nil, type: .cablecar, source: .live, createdAt: TestClock.date("2026-10-15 07:25"))
        let original = [night, tram, running]

        for delimiter in CSVOptions.Delimiter.allCases {
            var options = CSVOptions()
            options.delimiter = delimiter
            options.includeBOM = true
            let data = CSVExport.data(for: original, options: options, timeZone: zone)
            let imported = try CSVImport.segments(fromCSV: String(decoding: data, as: UTF8.self), timeZone: zone)

            XCTAssertEqual(imported.skippedLines, [])
            XCTAssertEqual(imported.segments, original, "Delimiter \(delimiter)")
        }
    }

    func testImportAcceptsFilesEditedInExcel() throws {
        let text = """
        date;start_time;end_time;movement_type;note
        2026-10-15;08:12;08:40;Walking;from Excel
        15.10.2026;23:30;00:15;Velo;
        2026-10-16;09:00:00;09:20:00;Bus / Tram;"quoted; with separator"
        nonsense;08:00;09:00;car;
        2026-10-15;08:00;09:00;plane;

        """
        let result = try CSVImport.segments(fromCSV: text, timeZone: zone)
        XCTAssertEqual(result.skippedLines, [5, 6])
        XCTAssertEqual(result.segments.count, 3)

        XCTAssertEqual(result.segments[0].type, .walking)
        XCTAssertEqual(result.segments[0].start, TestClock.date("2026-10-15 08:12"))
        XCTAssertEqual(result.segments[0].end, TestClock.date("2026-10-15 08:40"))
        XCTAssertEqual(result.segments[0].source, .imported)

        XCTAssertEqual(result.segments[1].type, .bike)
        XCTAssertEqual(result.segments[1].end, TestClock.date("2026-10-16 00:15"), "Ends after midnight")

        XCTAssertEqual(result.segments[2].type, .busTram)
        XCTAssertEqual(result.segments[2].note, "quoted; with separator")
    }

    func testImportRejectsFilesWithoutRequiredColumns() {
        XCTAssertThrowsError(try CSVImport.segments(fromCSV: "", timeZone: zone)) { error in
            XCTAssertEqual(error as? CSVImport.ImportError, .empty)
        }
        XCTAssertThrowsError(try CSVImport.segments(fromCSV: "foo,bar\n1,2\n", timeZone: zone)) { error in
            XCTAssertEqual(error as? CSVImport.ImportError, .missingColumns)
        }
    }

    func testParserHandlesQuotesLineBreaksAndBOM() {
        let text = "\u{FEFF}a,b,c\r\n1,\"x, \"\"y\"\"\",3\r\n\r\n4,\"multi\nline\",6\n7,,"
        XCTAssertEqual(CSVParser.rows(from: text), [
            ["a", "b", "c"],
            ["1", "x, \"y\"", "3"],
            ["4", "multi\nline", "6"],
            ["7", "", ""],
        ])
    }

    func testFileName() {
        XCTAssertEqual(CSVExport.fileName(first: nil, last: nil, timeZone: zone), "segments.csv")
        let day = TestClock.date("2026-10-15 08:00")
        XCTAssertEqual(CSVExport.fileName(first: day, last: day, timeZone: zone), "segments_2026-10-15.csv")
        XCTAssertEqual(
            CSVExport.fileName(first: TestClock.date("2026-10-01 08:00"), last: day, timeZone: zone),
            "segments_2026-10-01_to_2026-10-15.csv"
        )
    }
}

final class SegmentFileStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testMissingFileMeansNoData() throws {
        let store = SegmentFileStore(url: directory.appendingPathComponent("segments.json"))
        XCTAssertEqual(try store.load(), [])
    }

    func testSaveAndLoadRoundTrip() throws {
        let store = SegmentFileStore(url: directory.appendingPathComponent("nested/segments.json"))
        var segment = makeSegment(.ship, "2026-10-15 10:00", "2026-10-15 10:45", note: "Zürichsee")
        segment.createdAt = Date(timeIntervalSince1970: 1_760_000_000.123)
        let running = Segment(start: TestClock.date("2026-10-15 11:00"), end: nil, type: .walking, detectedActivity: .walking, createdAt: Date(timeIntervalSinceReferenceDate: 782_000_000.987654321))

        try store.save([segment, running])
        XCTAssertEqual(try store.load(), [segment, running])
    }

    func testUnreadableFileIsMovedAsideInsteadOfOverwritten() throws {
        let url = directory.appendingPathComponent("segments.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let store = SegmentFileStore(url: url)

        XCTAssertThrowsError(try store.load())
        let moved = try XCTUnwrap(store.quarantineUnreadableFile(now: Date(timeIntervalSince1970: 42)))
        XCTAssertEqual(moved.lastPathComponent, "segments-unreadable-42.json")
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "not json")
        XCTAssertEqual(try store.load(), [])
    }
}
