import Foundation

struct CSVOptions: Hashable, Sendable {
    enum Delimiter: String, CaseIterable, Hashable, Sendable {
        case comma = ","
        case semicolon = ";"

        var scalar: Unicode.Scalar { rawValue.unicodeScalars.first! }
    }

    var delimiter: Delimiter = .comma
    /// Byte order mark, so that Excel recognises UTF-8 (umlauts in notes).
    var includeBOM = false
    var includeRunning = true
}

/// Writes segments as CSV (RFC 4180).
enum CSVExport {
    static let columns = [
        "date", "start_time", "end_time", "duration_min", "movement_type", "note",
        "start_iso", "end_iso", "timezone", "source", "detected_activity",
        "id", "created_at", "updated_at",
    ]

    static func csv(for segments: [Segment], options: CSVOptions, timeZone: TimeZone) -> String {
        let formatters = CSVFormatters(timeZone: timeZone)
        let separator = options.delimiter.rawValue
        var lines = [columns.joined(separator: separator)]
        for segment in segments.sorted(by: SegmentBook.areInIncreasingOrder) {
            if segment.isRunning && !options.includeRunning {
                continue
            }
            let fields: [String] = [
                formatters.date.string(from: segment.start),
                formatters.time.string(from: segment.start),
                segment.end.map { formatters.time.string(from: $0) } ?? "",
                segment.end.map { String(Int(($0.timeIntervalSince(segment.start) / 60).rounded())) } ?? "",
                segment.type.rawValue,
                segment.note,
                formatters.iso.string(from: segment.start),
                segment.end.map { formatters.iso.string(from: $0) } ?? "",
                timeZone.identifier,
                segment.source.rawValue,
                segment.detectedActivity?.rawValue ?? "",
                segment.id.uuidString.lowercased(),
                formatters.iso.string(from: segment.createdAt),
                formatters.iso.string(from: segment.updatedAt),
            ]
            lines.append(fields.map { escape($0, delimiter: options.delimiter) }.joined(separator: separator))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    static func data(for segments: [Segment], options: CSVOptions, timeZone: TimeZone) -> Data {
        var data = Data()
        if options.includeBOM {
            data.append(contentsOf: [0xEF, 0xBB, 0xBF])
        }
        data.append(contentsOf: Array(csv(for: segments, options: options, timeZone: timeZone).utf8))
        return data
    }

    /// Quotes a field when it contains the delimiter, quotes, line breaks or outer spaces.
    static func escape(_ field: String, delimiter: CSVOptions.Delimiter) -> String {
        let scalars = field.unicodeScalars
        let needsQuotes = scalars.contains { $0 == delimiter.scalar || $0 == "\"" || $0 == "\n" || $0 == "\r" }
            || scalars.first == " " || scalars.last == " "
        guard needsQuotes else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// e.g. "segments_2026-10-15.csv" or "segments_2026-10-01_to_2026-10-15.csv".
    static func fileName(first: Date?, last: Date?, timeZone: TimeZone) -> String {
        let formatter = CSVFormatters(timeZone: timeZone).date
        guard let first, let last else { return "segments.csv" }
        let from = formatter.string(from: first)
        let to = formatter.string(from: last)
        return from == to ? "segments_\(from).csv" : "segments_\(from)_to_\(to).csv"
    }
}

/// Fixed, locale independent formats for the CSV file.
struct CSVFormatters {
    let date: DateFormatter
    let time: DateFormatter
    let timeWithSeconds: DateFormatter
    let iso: ISO8601DateFormatter

    init(timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let posix = Locale(identifier: "en_US_POSIX")

        date = DateFormatter()
        date.locale = posix
        date.calendar = calendar
        date.timeZone = timeZone
        date.dateFormat = "yyyy-MM-dd"

        time = DateFormatter()
        time.locale = posix
        time.calendar = calendar
        time.timeZone = timeZone
        time.dateFormat = "HH:mm"

        timeWithSeconds = DateFormatter()
        timeWithSeconds.locale = posix
        timeWithSeconds.calendar = calendar
        timeWithSeconds.timeZone = timeZone
        timeWithSeconds.dateFormat = "HH:mm:ss"

        iso = ISO8601DateFormatter()
        iso.timeZone = timeZone
        iso.formatOptions = [.withInternetDateTime]
    }
}

/// Minimal RFC 4180 reader. Detects comma or semicolon from the header line.
enum CSVParser {
    static func rows(from text: String) -> [[String]] {
        var scalars = Array(text.unicodeScalars)
        if scalars.first == "\u{FEFF}" {
            scalars.removeFirst()
        }
        let delimiter = detectDelimiter(in: scalars)

        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false
        var index = 0

        func endRow() {
            row.append(String(field))
            field = String.UnicodeScalarView()
            // Skip completely empty lines.
            if !(row.count == 1 && row[0].isEmpty) {
                rows.append(row)
            }
            row = []
        }

        while index < scalars.count {
            let scalar = scalars[index]
            if inQuotes {
                if scalar == "\"" {
                    if index + 1 < scalars.count && scalars[index + 1] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(scalar)
                }
            } else if scalar == "\"" {
                inQuotes = true
            } else if scalar == delimiter {
                row.append(String(field))
                field = String.UnicodeScalarView()
            } else if scalar == "\n" || scalar == "\r" {
                endRow()
                if scalar == "\r" && index + 1 < scalars.count && scalars[index + 1] == "\n" {
                    index += 1
                }
            } else {
                field.append(scalar)
            }
            index += 1
        }
        if !field.isEmpty || !row.isEmpty {
            endRow()
        }
        return rows
    }

    static func detectDelimiter(in scalars: [Unicode.Scalar]) -> Unicode.Scalar {
        var commas = 0
        var semicolons = 0
        var inQuotes = false
        for scalar in scalars {
            if scalar == "\"" {
                inQuotes.toggle()
            } else if !inQuotes {
                if scalar == "\n" || scalar == "\r" {
                    break
                }
                if scalar == "," {
                    commas += 1
                } else if scalar == ";" {
                    semicolons += 1
                }
            }
        }
        return semicolons > commas ? ";" : ","
    }
}

/// Reads segments back from a CSV file written by this app (or edited in Excel).
enum CSVImport {
    struct Result: Equatable, Sendable {
        var segments: [Segment]
        /// 1-based line numbers of rows that could not be read.
        var skippedLines: [Int]
    }

    enum ImportError: Error, Equatable {
        case empty
        case missingColumns
    }

    static func segments(fromCSV text: String, timeZone: TimeZone, now: Date = Date()) throws -> Result {
        let rows = CSVParser.rows(from: text)
        guard let header = rows.first else { throw ImportError.empty }
        let columns = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        func column(_ name: String) -> Int? { columns.firstIndex(of: name) }

        let typeColumn = column("movement_type")
        let startISOColumn = column("start_iso")
        let dateColumn = column("date")
        let startTimeColumn = column("start_time")
        guard typeColumn != nil, startISOColumn != nil || (dateColumn != nil && startTimeColumn != nil) else {
            throw ImportError.missingColumns
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // Excel likes to rewrite dates and times when a file is saved again, so accept a few layouts.
        let dateFormats = ["yyyy-MM-dd", "dd.MM.yyyy", "d.M.yyyy", "yyyy/MM/dd"].map { format(for: $0, timeZone: timeZone) }
        let timeFormats = ["HH:mm", "HH:mm:ss", "H:mm"].map { format(for: $0, timeZone: timeZone) }
        func parse(_ text: String, with formatters: [DateFormatter]) -> Date? {
            guard !text.isEmpty else { return nil }
            return formatters.lazy.compactMap { $0.date(from: text) }.first
        }

        var segments: [Segment] = []
        var skipped: [Int] = []
        for (offset, row) in rows.dropFirst().enumerated() {
            let line = offset + 2
            func value(_ index: Int?) -> String {
                guard let index, index < row.count else { return "" }
                return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
            }

            guard let type = MovementType(csvValue: value(typeColumn)) else {
                skipped.append(line)
                continue
            }

            var start = parseISO(value(startISOColumn))
            if start == nil,
               let day = parse(value(dateColumn), with: dateFormats),
               let time = parse(value(startTimeColumn), with: timeFormats) {
                start = calendar.moving(time, toDayOf: day)
            }
            guard let start else {
                skipped.append(line)
                continue
            }

            var end = parseISO(value(column("end_iso")))
            if end == nil, let time = parse(value(column("end_time")), with: timeFormats) {
                end = calendar.end(forStart: start, endTimeOfDay: time)
            }
            if let end, end <= start {
                skipped.append(line)
                continue
            }

            let source = Segment.Source(rawValue: value(column("source"))) ?? .imported
            let created = parseISO(value(column("created_at"))) ?? now
            segments.append(Segment(
                id: UUID(uuidString: value(column("id"))) ?? UUID(),
                start: start,
                end: end,
                type: type,
                note: value(column("note")),
                source: source,
                detectedActivity: DetectedActivity(rawValue: value(column("detected_activity"))),
                createdAt: created,
                updatedAt: parseISO(value(column("updated_at"))) ?? created
            ))
        }
        return Result(segments: segments, skippedLines: skipped)
    }

    private static func format(for pattern: String, timeZone: TimeZone) -> DateFormatter {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        formatter.isLenient = false
        return formatter
    }

    private static func parseISO(_ text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}
