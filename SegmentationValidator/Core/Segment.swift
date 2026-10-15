import Foundation

/// One logged movement segment: from `start` to `end` the user was doing `type`.
struct Segment: Codable, Identifiable, Hashable, Sendable {
    /// How the segment was created. Exported to the CSV so the data can be audited later.
    enum Source: String, Codable, CaseIterable, Sendable {
        /// Typed in with the editor.
        case manual
        /// Started and stopped with the live buttons.
        case live
        /// Accepted from a movement detected by the motion sensor.
        case suggestion
        /// Created from a movement reminder notification.
        case reminder
        /// Imported from a CSV file.
        case imported
    }

    var id: UUID
    var start: Date
    /// `nil` while the segment is still running.
    var end: Date?
    var type: MovementType
    var note: String
    var source: Source
    /// What the motion sensor detected, when the segment came from a detection.
    var detectedActivity: DetectedActivity?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        start: Date,
        end: Date?,
        type: MovementType,
        note: String = "",
        source: Source = .manual,
        detectedActivity: DetectedActivity? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.type = type
        self.note = note
        self.source = source
        self.detectedActivity = detectedActivity
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    var isRunning: Bool { end == nil }

    /// End used for display and calculations. A running segment ends "now".
    func effectiveEnd(now: Date) -> Date {
        max(end ?? now, start)
    }

    func duration(now: Date) -> TimeInterval {
        effectiveEnd(now: now).timeIntervalSince(start)
    }

    func interval(now: Date) -> DateInterval {
        DateInterval(start: start, end: effectiveEnd(now: now))
    }

    /// True when both segments describe the same thing (ignores ids and timestamps).
    func hasSameContent(as other: Segment) -> Bool {
        start == other.start && end == other.end && type == other.type && note == other.note
    }

    // Lenient decoding, so that files written by older or newer versions still load.
    private enum CodingKeys: String, CodingKey {
        case id, start, end, type, note, source, detectedActivity, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        start = try container.decode(Date.self, forKey: .start)
        end = try container.decodeIfPresent(Date.self, forKey: .end)
        type = try container.decode(MovementType.self, forKey: .type)
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        source = (try? container.decodeIfPresent(Source.self, forKey: .source)) ?? .manual
        detectedActivity = try? container.decodeIfPresent(DetectedActivity.self, forKey: .detectedActivity)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? start
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}
