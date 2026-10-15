import SwiftUI

/// The week around the selected day. Tap a day to open it, swipe to change the week.
struct WeekStrip: View {
    @Binding var selectedDay: Date
    let daysWithData: Set<Date>
    let onCalendarTap: () -> Void

    private var calendar: Calendar { .current }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Button {
                    shift(byWeeks: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .padding(8)
                }
                .accessibilityLabel("Previous week")

                Spacer()

                Button(action: onCalendarTap) {
                    HStack(spacing: 4) {
                        Text(Formatting.monthTitle(selectedDay))
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.bold))
                    }
                    .font(.subheadline.weight(.semibold))
                }
                .accessibilityHint("Opens a calendar to pick any day")

                Spacer()

                Button {
                    shift(byWeeks: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .padding(8)
                }
                .accessibilityLabel("Next week")
            }

            HStack(spacing: 0) {
                ForEach(week(containing: selectedDay), id: \.self) { day in
                    DayCell(
                        day: day,
                        isSelected: calendar.isDate(day, inSameDayAs: selectedDay),
                        isToday: calendar.isDateInToday(day),
                        hasData: daysWithData.contains(day)
                    )
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedDay = day
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .background(.bar)
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    if value.translation.width < -40 {
                        shift(byWeeks: 1)
                    } else if value.translation.width > 40 {
                        shift(byWeeks: -1)
                    }
                }
        )
    }

    private func week(containing date: Date) -> [Date] {
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private func shift(byWeeks weeks: Int) {
        guard let day = calendar.date(byAdding: .weekOfYear, value: weeks, to: selectedDay) else { return }
        withAnimation(.snappy) {
            selectedDay = calendar.startOfDay(for: day)
        }
    }
}

private struct DayCell: View {
    let day: Date
    let isSelected: Bool
    let isToday: Bool
    let hasData: Bool

    var body: some View {
        VStack(spacing: 4) {
            Text(day.formatted(.dateTime.weekday(.abbreviated)))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(day.formatted(.dateTime.day()))
                .font(.body.weight(isSelected || isToday ? .bold : .regular))
                .monospacedDigit()
                .foregroundStyle(isSelected ? Color.white : (isToday ? Color.accentColor : Color.primary))
                .frame(width: 36, height: 36)
                .background(Circle().fill(isSelected ? Color.accentColor : Color.clear))
            Circle()
                .fill(hasData ? Color.accentColor : Color.clear)
                .frame(width: 5, height: 5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Formatting.dayTitle(day))
        .accessibilityValue(hasData ? String(localized: "has segments") : "")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Calendar sheet to jump to any day.
struct DatePickerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                DatePicker("Day", selection: dayBinding, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .padding(.horizontal)
            }
            .navigationTitle("Choose a day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Today") {
                        model.selectedDay = Calendar.current.startOfDay(for: .now)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var dayBinding: Binding<Date> {
        Binding(
            get: { model.selectedDay },
            set: { newValue in
                model.selectedDay = Calendar.current.startOfDay(for: newValue)
                dismiss()
            }
        )
    }
}
