import Foundation

/// Writes location points as CSV (RFC 4180), one row per point.
enum LocationCSVExport {
    static let columns = [
        "date", "time", "timestamp_iso", "timezone", "latitude", "longitude", "accuracy_m",
        "altitude_m", "speed_mps", "distance_m", "movement_type", "trigger", "prompt", "answer", "id",
    ]

    /// `book` provides the movement type logged at the time of each point.
    static func csv(
        for points: [LocationPoint],
        book: SegmentBook,
        options: CSVOptions,
        timeZone: TimeZone,
        now: Date
    ) -> String {
        let formatters = CSVFormatters(timeZone: timeZone)
        let separator = options.delimiter.rawValue
        var lines = [columns.joined(separator: separator)]
        var previous: LocationPoint?
        for point in points.sorted(by: { $0.timestamp < $1.timestamp }) {
            let fields: [String] = [
                formatters.date.string(from: point.timestamp),
                formatters.timeWithSeconds.string(from: point.timestamp),
                formatters.iso.string(from: point.timestamp),
                timeZone.identifier,
                number(point.latitude, decimals: 6),
                number(point.longitude, decimals: 6),
                point.accuracy >= 0 ? number(point.accuracy, decimals: 1) : "",
                point.altitude.map { number($0, decimals: 1) } ?? "",
                point.speed.map { number($0, decimals: 2) } ?? "",
                previous.map { number($0.distance(to: point), decimals: 0) } ?? "",
                book.segment(at: point.timestamp, now: now)?.type.rawValue ?? "",
                point.trigger.rawValue,
                point.prompt?.rawValue ?? "",
                point.answer.map { $0 ? "true" : "false" } ?? "",
                point.id.uuidString.lowercased(),
            ]
            lines.append(fields.map { CSVExport.escape($0, delimiter: options.delimiter) }.joined(separator: separator))
            previous = point
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    static func data(
        for points: [LocationPoint],
        book: SegmentBook,
        options: CSVOptions,
        timeZone: TimeZone,
        now: Date
    ) -> Data {
        var data = Data()
        if options.includeBOM {
            data.append(contentsOf: [0xEF, 0xBB, 0xBF])
        }
        data.append(contentsOf: Array(csv(for: points, book: book, options: options, timeZone: timeZone, now: now).utf8))
        return data
    }

    /// e.g. "locations_2026-10-15.csv" or "locations_2026-10-01_to_2026-10-15.csv".
    static func fileName(first: Date?, last: Date?, timeZone: TimeZone) -> String {
        let formatter = CSVFormatters(timeZone: timeZone).date
        guard let first, let last else { return "locations.csv" }
        let from = formatter.string(from: first)
        let to = formatter.string(from: last)
        return from == to ? "locations_\(from).csv" : "locations_\(from)_to_\(to).csv"
    }

    /// Locale independent: always a decimal point, never a thousands separator.
    private static func number(_ value: Double, decimals: Int) -> String {
        String(format: "%.\(decimals)f", value)
    }
}
