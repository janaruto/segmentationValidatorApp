import SwiftUI

/// The main screen: one day with its segments, gaps, live logging and detected movements.
struct DayView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let day = model.selectedDay
        let timeline = model.timeline(for: day)
        let suggestions = model.suggestions(for: day)
        let isToday = Calendar.current.isDateInToday(day)

        NavigationStack {
            List {
                if isToday {
                    Section {
                        LiveLoggingCard()
                    }
                }

                Section {
                    if timeline.entries.isEmpty {
                        EmptyDayView(isToday: isToday)
                    } else {
                        ForEach(timeline.entries) { entry in
                            switch entry {
                            case .segment(let segment):
                                segmentRow(segment, day: day, isOverlapping: timeline.overlappingIDs.contains(segment.id))
                            case .gap(let gap):
                                GapRow(gap: gap) {
                                    model.fill(gap)
                                }
                            }
                        }
                    }
                } header: {
                    DaySummaryHeader(timeline: timeline)
                }

                SuggestionsSection(day: day, suggestions: suggestions)
            }
            .listStyle(.insetGrouped)
            .animation(.default, value: model.revision)
            .safeAreaInset(edge: .top, spacing: 0) {
                WeekStrip(selectedDay: $model.selectedDay, daysWithData: model.daysWithData) {
                    model.sheet = .datePicker
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomBar(day: day)
            }
            .navigationTitle(Formatting.dayTitle(day))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !isToday {
                        Button("Today") {
                            withAnimation {
                                model.selectedDay = Calendar.current.startOfDay(for: .now)
                            }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.sheet = .datePicker
                    } label: {
                        Image(systemName: "calendar")
                    }
                    .accessibilityLabel("Choose a day")
                }
            }
            .refreshable {
                await model.refreshDetections(for: day)
            }
            .task(id: day) {
                await model.refreshDetections(for: day)
            }
        }
    }

    private func segmentRow(_ segment: Segment, day: Date, isOverlapping: Bool) -> some View {
        Button {
            model.edit(segment)
        } label: {
            SegmentRow(segment: segment, day: day, isOverlapping: isOverlapping)
        }
        .foregroundStyle(.primary)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                model.delete(segment)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                model.addSegment(after: segment)
            } label: {
                Label("Add after", systemImage: "text.badge.plus")
            }
            .tint(.accentColor)
        }
        .contextMenu {
            Button {
                model.edit(segment)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button {
                model.addSegment(after: segment)
            } label: {
                Label("Add segment after", systemImage: "text.badge.plus")
            }
            Button(role: .destructive) {
                model.delete(segment)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func bottomBar(day: Date) -> some View {
        VStack(spacing: 8) {
            if let deleted = model.recentlyDeleted {
                UndoBanner(segment: deleted)
            }
            Button {
                model.addSegment(on: day)
            } label: {
                Label("Add segment", systemImage: "plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(.bar)
        .animation(.snappy, value: model.recentlyDeleted?.id)
    }
}

/// Header of the segment list: how much of the day is logged.
struct DaySummaryHeader: View {
    let timeline: DayTimeline

    var body: some View {
        HStack {
            Text("Segments")
            Spacer()
            if !timeline.segments.isEmpty {
                Text(L10n.format(
                    "%1$lld · %2$@ logged",
                    timeline.segments.count,
                    DurationText.short(timeline.loggedDuration)
                ))
                .monospacedDigit()
            }
        }
    }
}

struct SegmentRow: View {
    let segment: Segment
    let day: Date
    var isOverlapping = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TypeIcon(type: segment.type)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(segment.type.displayName)
                        .font(.headline)
                    if segment.isRunning {
                        RunningBadge()
                    }
                    Spacer(minLength: 8)
                    DurationLabel(segment: segment)
                }
                Text(Formatting.range(of: segment, on: day))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                if !segment.note.isEmpty {
                    Text(segment.note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if isOverlapping {
                    Label("Overlaps another segment", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

struct GapRow: View {
    let gap: TimelineGap
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "plus.circle")
                    .font(.title3)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.format("Gap %1$@ – %2$@", Formatting.time(gap.start), Formatting.time(gap.end)))
                        .font(.subheadline.weight(.medium))
                    Text(L10n.format("%@ not logged · tap to fill", DurationText.short(gap.duration)))
                        .font(.caption)
                }
                Spacer()
            }
            .foregroundStyle(.orange)
        }
    }
}

struct EmptyDayView: View {
    let isToday: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "figure.walk.motion")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No segments yet")
                .font(.headline)
            Group {
                if isToday {
                    Text("Start a segment above or tap Add segment below.")
                } else {
                    Text("Tap Add segment to log what you did on this day.")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

struct UndoBanner: View {
    @Environment(AppModel.self) private var model
    let segment: Segment

    var body: some View {
        HStack {
            Image(systemName: "trash")
                .foregroundStyle(.secondary)
            Text(L10n.format("Deleted: %@", segment.type.displayName))
                .font(.subheadline)
            Spacer()
            Button("Undo") {
                model.undoDelete()
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
