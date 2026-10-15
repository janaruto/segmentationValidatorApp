import Foundation

/// The editable form of a segment before it is saved.
struct SegmentDraft: Equatable, Sendable {
    /// Set when an existing segment is edited.
    var editingID: UUID?
    var start: Date
    /// `nil` means the segment is still running.
    var end: Date?
    /// `nil` until the user picked a type.
    var type: MovementType?
    var note: String
    var source: Segment.Source
    var detectedActivity: DetectedActivity?

    init(
        editingID: UUID? = nil,
        start: Date,
        end: Date?,
        type: MovementType? = nil,
        note: String = "",
        source: Segment.Source = .manual,
        detectedActivity: DetectedActivity? = nil
    ) {
        self.editingID = editingID
        self.start = start
        self.end = end
        self.type = type
        self.note = note
        self.source = source
        self.detectedActivity = detectedActivity
    }

    init(editing segment: Segment) {
        self.init(
            editingID: segment.id,
            start: segment.start,
            end: segment.end,
            type: segment.type,
            note: segment.note,
            source: segment.source,
            detectedActivity: segment.detectedActivity
        )
    }

    var isEditing: Bool { editingID != nil }

    var trimmedNote: String {
        note.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Problems that prevent saving a draft.
enum DraftError: Error, Equatable, Sendable {
    case missingType
    case endNotAfterStart
    case runningStartsInFuture
    case anotherSegmentRunning
}

/// Things worth a second look. Saving is still allowed.
enum DraftWarning: Equatable, Sendable {
    case startsInFuture
    case veryLong
    case overlaps([Segment])
}

struct DraftValidation: Equatable, Sendable {
    var errors: [DraftError] = []
    var warnings: [DraftWarning] = []
    /// The running segment that gets ended when the draft is saved.
    var endsRunningSegment: Segment?

    var canSave: Bool { errors.isEmpty }
}

/// How one segment connects to the next one.
enum Continuity: Equatable, Sendable {
    /// The previous segment ends exactly when the next one starts.
    case seamless
    /// Time in between that is not logged.
    case gap(TimeInterval)
    /// Both segments claim the same time.
    case overlap(TimeInterval)
    /// The previous segment is still running.
    case running

    /// How a segment ending at `end` (`nil` = running) connects to one starting at `start`.
    static func between(end: Date?, start: Date) -> Continuity {
        guard let end else { return .running }
        let difference = start.flooredToMinute.timeIntervalSince(end.flooredToMinute)
        if difference == 0 {
            return .seamless
        }
        return difference > 0 ? .gap(difference) : .overlap(-difference)
    }
}
