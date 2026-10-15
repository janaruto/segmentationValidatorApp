import SwiftUI

/// Shows one or more drafts in a row ("Save & next" for trips with several detected parts).
struct SegmentEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: EditorRequest

    @State private var index = 0
    @State private var savedCount = 0

    var body: some View {
        NavigationStack {
            SegmentEditorForm(
                draft: request.drafts[index],
                origin: request.origin,
                part: request.drafts.count > 1 ? (index + 1, request.drafts.count) : nil,
                onCancel: { dismiss() },
                onSave: save,
                onSkip: index + 1 < request.drafts.count ? advance : nil,
                onDelete: { id in
                    model.deleteSegment(id: id)
                    dismiss()
                }
            )
            .id(index)
        }
        .sensoryFeedback(.success, trigger: savedCount)
        .alert(model.alert?.title ?? "", isPresented: alertBinding, presenting: model.alert) { _ in
            Button("OK", role: .cancel) {}
        } message: { alert in
            Text(alert.message)
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { model.alert != nil },
            set: { isPresented in
                if !isPresented {
                    model.alert = nil
                }
            }
        )
    }

    private func save(_ draft: SegmentDraft) {
        guard model.save(draft) else { return }
        savedCount += 1
        advance()
    }

    private func advance() {
        if index + 1 < request.drafts.count {
            withAnimation {
                index += 1
            }
        } else {
            dismiss()
        }
    }
}

/// The editor for a single segment.
struct SegmentEditorForm: View {
    @Environment(AppModel.self) private var model

    let original: SegmentDraft
    let origin: EditorRequest.Origin
    /// (current, total) when several detected parts are edited in a row.
    let part: (Int, Int)?
    let onCancel: () -> Void
    let onSave: (SegmentDraft) -> Void
    let onSkip: (() -> Void)?
    let onDelete: (UUID) -> Void

    @State private var type: MovementType?
    @State private var start: Date
    @State private var endTime: Date
    @State private var isRunning: Bool
    @State private var note: String
    @State private var confirmingDelete = false

    init(
        draft: SegmentDraft,
        origin: EditorRequest.Origin,
        part: (Int, Int)?,
        onCancel: @escaping () -> Void,
        onSave: @escaping (SegmentDraft) -> Void,
        onSkip: (() -> Void)?,
        onDelete: @escaping (UUID) -> Void
    ) {
        original = draft
        self.origin = origin
        self.part = part
        self.onCancel = onCancel
        self.onSave = onSave
        self.onSkip = onSkip
        self.onDelete = onDelete
        _type = State(initialValue: draft.type)
        _start = State(initialValue: draft.start)
        _endTime = State(initialValue: draft.end ?? Date().flooredToMinute)
        _isRunning = State(initialValue: draft.end == nil)
        _note = State(initialValue: draft.note)
    }

    private var calendar: Calendar { .current }

    private var end: Date? {
        isRunning ? nil : calendar.end(forStart: start, endTimeOfDay: endTime)
    }

    private var draft: SegmentDraft {
        var draft = original
        draft.type = type
        draft.start = start.flooredToMinute
        draft.end = end?.flooredToMinute
        draft.note = note
        return draft
    }

    private var validation: DraftValidation {
        model.book.validate(draft, now: .now)
    }

    private var previous: Segment? {
        model.book.previous(before: draft.start, excluding: original.editingID)
    }

    private var next: Segment? {
        model.book.next(after: draft.start, excluding: original.editingID)
    }

    /// Running is only offered for segments that started recently.
    private var canRun: Bool {
        let age = Date().timeIntervalSince(start)
        return original.end == nil || (age >= 0 && age < 24 * 3600)
    }

    var body: some View {
        Form {
            if let banner = originBanner {
                Section {
                    banner
                }
            }

            continuitySection

            Section {
                if original.detectedActivity == .automotive && type == nil {
                    Label("The phone noticed a vehicle. Which one was it?", systemImage: "car.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                MovementTypeGrid(
                    selection: $type,
                    highlighted: original.detectedActivity == .automotive ? MovementType.vehicles : []
                )
            } header: {
                Text("Movement type")
            }

            timeSection

            Section {
                TextField("Optional note", text: $note, axis: .vertical)
                    .lineLimit(1...4)
            } header: {
                Text("Note")
            }

            issuesSection

            if let id = original.editingID {
                Section {
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Label("Delete segment", systemImage: "trash")
                    }
                    .confirmationDialog("Delete this segment?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                        Button("Delete", role: .destructive) {
                            onDelete(id)
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(saveTitle) {
                    onSave(draft)
                }
                .fontWeight(.semibold)
                .disabled(!validation.canSave)
            }
            if let onSkip {
                ToolbarItem(placement: .bottomBar) {
                    Button("Skip this part", action: onSkip)
                }
            }
        }
    }

    // MARK: - Sections

    private var title: String {
        if let part {
            return L10n.format("Part %1$lld of %2$lld", part.0, part.1)
        }
        return original.isEditing ? String(localized: "Edit segment") : String(localized: "New segment")
    }

    private var saveTitle: String {
        if let part, part.0 < part.1 {
            return String(localized: "Save & next")
        }
        return String(localized: "Save")
    }

    private var originBanner: AnyView? {
        switch origin {
        case .reminder(let reminder):
            return AnyView(DetectionBanner(
                title: String(localized: "Detected by the motion sensor"),
                detail: detectionDetail(activity: original.detectedActivity ?? reminder.activity)
            ))
        case .suggestion:
            return AnyView(DetectionBanner(
                title: String(localized: "Detected by the motion sensor"),
                detail: detectionDetail(activity: original.detectedActivity ?? .unknown)
            ))
        case .manual, .edit, .gap:
            return nil
        }
    }

    private func detectionDetail(activity: DetectedActivity) -> String {
        let range = Formatting.range(start: original.start, end: original.end, on: original.start)
        return "\(activity.displayName) · \(Formatting.shortDay(original.start)) · \(range)"
    }

    @ViewBuilder
    private var continuitySection: some View {
        Section {
            if let previous {
                NeighborRow(
                    title: String(localized: "Previous segment"),
                    segment: previous,
                    continuity: Continuity.between(end: previous.end, start: draft.start),
                    fixTitle: previous.end.map { L10n.format("Start at %@", Formatting.time($0)) },
                    fix: {
                        if let previousEnd = previous.end {
                            moveStart(to: previousEnd)
                        }
                    }
                )
            } else {
                Label("No earlier segment", systemImage: "arrow.up.to.line")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let next {
                NeighborRow(
                    title: String(localized: "Next segment"),
                    segment: next,
                    continuity: Continuity.between(end: draft.end, start: next.start),
                    fixTitle: L10n.format("End at %@", Formatting.time(next.start)),
                    fix: {
                        isRunning = false
                        endTime = next.start
                    }
                )
            }
        } header: {
            Text("Check against your other segments")
        }
    }

    private var timeSection: some View {
        Section {
            DatePicker("Date", selection: dayBinding, displayedComponents: .date)
            DatePicker("Start", selection: $start, displayedComponents: .hourAndMinute)
            if canRun {
                Toggle("Still running", isOn: $isRunning)
            }
            if !isRunning {
                DatePicker("End", selection: $endTime, displayedComponents: .hourAndMinute)
                if let end, !calendar.isDate(end, inSameDayAs: start) {
                    Label("Ends on the next day", systemImage: "moon.stars")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Duration") {
                    Text(DurationText.short((end ?? start).timeIntervalSince(start.flooredToMinute)))
                        .monospacedDigit()
                }
                if start <= Date() {
                    Button("End now") {
                        endTime = Date().flooredToMinute
                    }
                }
            }
        } header: {
            Text("Time")
        } footer: {
            if isRunning {
                Text("A running segment ends when you tap Stop or start another one.")
            }
        }
    }

    @ViewBuilder
    private var issuesSection: some View {
        let messages = issueMessages(self.validation)
        if !messages.isEmpty {
            Section {
                ForEach(messages, id: \.text) { message in
                    Label(message.text, systemImage: message.isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(message.isError ? Color.red : Color.orange)
                }
            }
        }
    }

    private struct IssueMessage {
        var text: String
        var isError: Bool
    }

    private func issueMessages(_ validation: DraftValidation) -> [IssueMessage] {
        var messages = validation.errors
            .filter { $0 != .missingType }
            .map { IssueMessage(text: $0.message, isError: true) }
        if let running = validation.endsRunningSegment {
            messages.append(IssueMessage(
                text: L10n.format("The running segment (%1$@) will end at %2$@.", running.type.displayName, Formatting.time(draft.start)),
                isError: false
            ))
        }
        for warning in validation.warnings {
            switch warning {
            case .startsInFuture:
                messages.append(IssueMessage(text: String(localized: "The start is in the future."), isError: false))
            case .veryLong:
                messages.append(IssueMessage(text: String(localized: "This segment is longer than 12 hours. Is that right?"), isError: false))
            case .overlaps(let segments):
                let names = segments
                    .map { "\($0.type.displayName) \(Formatting.range(of: $0, on: draft.start))" }
                    .joined(separator: ", ")
                messages.append(IssueMessage(text: L10n.format("Overlaps with: %@", names), isError: false))
            }
        }
        return messages
    }

    // MARK: - Bindings

    /// Changing the date keeps the times of day.
    private var dayBinding: Binding<Date> {
        Binding(
            get: { start },
            set: { newDay in
                start = calendar.moving(start, toDayOf: newDay)
            }
        )
    }

    private func moveStart(to date: Date) {
        let duration = end.map { $0.timeIntervalSince(start) }
        start = date.flooredToMinute
        if let duration, duration > 0 {
            endTime = start.addingTimeInterval(duration)
        }
    }
}

/// Context card: the neighbouring segment and how it connects to the edited one.
private struct NeighborRow: View {
    let title: String
    let segment: Segment
    let continuity: Continuity
    let fixTitle: String?
    let fix: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                TypeIcon(type: segment.type, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(segment.type.displayName)
                        .font(.subheadline.weight(.semibold))
                    Text(verbatim: "\(Formatting.shortDay(segment.start)) · \(Formatting.range(of: segment, on: segment.start))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack {
                Label(continuity.message, systemImage: continuity.isProblem ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(continuity.isProblem ? Color.orange : Color.green)
                Spacer()
                if continuity.isProblem, let fixTitle {
                    Button(fixTitle, action: fix)
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct DetectionBanner: View {
    let title: String
    let detail: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(Color.accentColor)
        }
    }
}
