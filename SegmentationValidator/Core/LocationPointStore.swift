import Foundation

/// Stores the location points on the device, one JSON file per day ("2026-10-20.json").
///
/// Small files keep each write fast (a day has at most a few hundred points) and make it
/// cheap to read a single day for the map.
struct LocationPointStore: Sendable {
    /// Bump when the file layout changes in a way older versions cannot read.
    static let currentVersion = 1

    private struct Archive: Codable {
        var version: Int
        var points: [LocationPoint]
    }

    let folder: URL

    /// "2026-10-20" in the calendar's time zone.
    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    func url(for day: Date, calendar: Calendar) -> URL {
        folder.appendingPathComponent(Self.dayKey(day, calendar: calendar) + ".json")
    }

    /// The points of one day, oldest first. A missing file means no points.
    func load(day: Date, calendar: Calendar) throws -> [LocationPoint] {
        let url = url(for: day, calendar: calendar)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return try decoder.decode(Archive.self, from: data).points.sorted { $0.timestamp < $1.timestamp }
    }

    /// Writes the points of one day atomically.
    func save(_ points: [LocationPoint], day: Date, calendar: Calendar) throws {
        let url = url(for: day, calendar: calendar)
        if points.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.sortedKeys]
        let sorted = points.sorted { $0.timestamp < $1.timestamp }
        let data = try encoder.encode(Archive(version: Self.currentVersion, points: sorted))
        try data.write(to: url, options: .atomic)
    }

    /// Start of every day that has a file, oldest first.
    func storedDays(calendar: Calendar) -> [Date] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap { name -> Date? in
            guard name.hasSuffix(".json") else { return nil }
            let parts = name.dropLast(5).split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        }
        .sorted()
    }

    /// All points between two dates, oldest first. Unreadable files are skipped.
    func points(from start: Date, to end: Date, calendar: Calendar) -> [LocationPoint] {
        let firstDay = calendar.startOfDay(for: start)
        return storedDays(calendar: calendar)
            .filter { $0 >= firstDay && $0 <= end }
            .flatMap { (try? load(day: $0, calendar: calendar)) ?? [] }
            .filter { $0.timestamp >= start && $0.timestamp <= end }
            .sorted { $0.timestamp < $1.timestamp }
    }

    func deleteAll() throws {
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    /// Moves an unreadable file out of the way instead of overwriting it, so nothing is lost.
    @discardableResult
    func quarantine(day: Date, calendar: Calendar, now: Date = Date()) -> URL? {
        let url = url(for: day, calendar: calendar)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let name = "\(Self.dayKey(day, calendar: calendar))-unreadable-\(Int(now.timeIntervalSince1970)).bak"
        let target = folder.appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: url, to: target)
            return target
        } catch {
            return nil
        }
    }
}
