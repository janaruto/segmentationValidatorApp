import SwiftUI

/// Month overview: which days have segments and how the time is spread over the movement types.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var month = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now

    var body: some View {
        let calendar = Calendar.current
        let interval = calendar.dateInterval(of: .month, for: month) ?? DateInterval(start: month, duration: 31 * 86_400)
        let typesByDay = model.typesByDay(in: interval)
        let totals = model.totals(in: interval)
        let days = model.daysWithData
            .filter { $0 >= interval.start && $0 < interval.end }
            .sorted(by: >)

        NavigationStack {
            List {
                Section {
                    MonthCalendar(month: $month, typesByDay: typesByDay) { day in
                        model.showDay(day)
                    }
                } footer: {
                    Text("Tap a day to open it. The dots show the logged movement types.")
                }

                Section {
                    if totals.isEmpty {
                        Text("No segments in this month yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(totals, id: \.type) { total in
                            TotalRow(total: total, maximum: totals.first?.duration ?? 1)
                        }
                    }
                } header: {
                    Text("Time per movement type")
                }

                if !days.isEmpty {
                    Section {
                        ForEach(days, id: \.self) { day in
                            Button {
                                model.showDay(day)
                            } label: {
                                HistoryDayRow(day: day, timeline: model.timeline(for: day))
                            }
                            .foregroundStyle(.primary)
                        }
                    } header: {
                        Text("Days with segments")
                    }
                }
            }
            .navigationTitle("History")
        }
    }
}

struct MonthCalendar: View {
    @Binding var month: Date
    let typesByDay: [Date: [MovementType]]
    let onSelect: (Date) -> Void

    private var calendar: Calendar { .current }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button {
                    shift(byMonths: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .padding(6)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Previous month")

                Spacer()
                Text(Formatting.monthTitle(month))
                    .font(.headline)
                Spacer()

                Button {
                    shift(byMonths: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .padding(6)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Next month")
            }

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                    if let day {
                        MonthDayCell(day: day, types: typesByDay[day] ?? [], isToday: calendar.isDateInToday(day))
                            .onTapGesture {
                                onSelect(day)
                            }
                    } else {
                        Color.clear
                            .frame(height: 40)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = max(0, min(symbols.count - 1, calendar.firstWeekday - 1))
        return Array(symbols[first...]) + Array(symbols[..<first])
    }

    /// The days of the month, with `nil` placeholders before the first weekday.
    private var cells: [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return [] }
        let weekday = calendar.component(.weekday, from: interval.start)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: leading)
        var day = interval.start
        while day < interval.end {
            cells.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return cells
    }

    private func shift(byMonths months: Int) {
        guard let date = calendar.date(byAdding: .month, value: months, to: month) else { return }
        withAnimation(.snappy) {
            month = calendar.dateInterval(of: .month, for: date)?.start ?? date
        }
    }
}

private struct MonthDayCell: View {
    let day: Date
    let types: [MovementType]
    let isToday: Bool

    var body: some View {
        VStack(spacing: 3) {
            Text(day.formatted(.dateTime.day()))
                .font(.callout.weight(isToday ? .bold : .regular))
                .monospacedDigit()
                .foregroundStyle(isToday ? Color.accentColor : Color.primary)
            HStack(spacing: 2) {
                ForEach(types.prefix(4), id: \.self) { type in
                    Circle()
                        .fill(type.color)
                        .frame(width: 5, height: 5)
                }
            }
            .frame(height: 5)
        }
        .frame(maxWidth: .infinity, minHeight: 40)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(types.isEmpty ? Color.clear : Color.accentColor.opacity(0.08))
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Formatting.dayTitle(day))
        .accessibilityValue(types.map(\.displayName).joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
    }
}

private struct TotalRow: View {
    let total: TypeTotal
    let maximum: TimeInterval

    var body: some View {
        HStack(spacing: 10) {
            TypeIcon(type: total.type, size: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(total.type.displayName)
                        .font(.subheadline)
                    Spacer()
                    Text(DurationText.short(total.duration))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                GeometryReader { proxy in
                    Capsule()
                        .fill(total.type.color.opacity(0.8))
                        .frame(width: max(4, proxy.size.width * total.duration / max(maximum, 1)))
                }
                .frame(height: 6)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct HistoryDayRow: View {
    let day: Date
    let timeline: DayTimeline

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Formatting.dayTitle(day))
                    .font(.subheadline.weight(.semibold))
                Text(L10n.format(
                    "Segments: %1$lld · %2$@ logged",
                    timeline.segments.count,
                    DurationText.short(timeline.loggedDuration)
                ))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: -6) {
                ForEach(distinctTypes.prefix(4), id: \.self) { type in
                    TypeIcon(type: type, size: 22)
                }
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    private var distinctTypes: [MovementType] {
        var seen: [MovementType] = []
        for segment in timeline.segments where !seen.contains(segment.type) {
            seen.append(segment.type)
        }
        return seen
    }
}
