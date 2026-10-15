import Foundation

/// Stores all segments in one JSON file on the device. No server, no cloud.
struct SegmentFileStore {
    /// Bump when the file layout changes in a way older versions cannot read.
    static let currentVersion = 1

    private struct Archive: Codable {
        var version: Int
        var segments: [Segment]
    }

    let url: URL

    /// Loads all segments. A missing file simply means no data yet.
    func load() throws -> [Segment] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        // Dates are stored as seconds since 2001 (Foundation's native format), so they round-trip exactly.
        decoder.dateDecodingStrategy = .deferredToDate
        return try decoder.decode(Archive.self, from: data).segments
    }

    /// Writes all segments atomically, so a crash can never leave a half-written file.
    func save(_ segments: [Segment]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Archive(version: Self.currentVersion, segments: segments))
        try data.write(to: url, options: .atomic)
    }

    /// Moves an unreadable file out of the way instead of overwriting it, so nothing is lost.
    @discardableResult
    func quarantineUnreadableFile(now: Date = Date()) -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let stamp = Int(now.timeIntervalSince1970)
        let target = url.deletingLastPathComponent().appendingPathComponent("segments-unreadable-\(stamp).json")
        do {
            try FileManager.default.moveItem(at: url, to: target)
            return target
        } catch {
            return nil
        }
    }
}
