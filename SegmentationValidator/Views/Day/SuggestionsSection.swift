import SwiftUI

/// Movements the motion sensor detected that are not logged yet.
struct SuggestionsSection: View {
    @Environment(AppModel.self) private var model
    let day: Date
    let suggestions: [Suggestion]

    var body: some View {
        if !suggestions.isEmpty {
            Section {
                ForEach(suggestions) { suggestion in
                    SuggestionRow(suggestion: suggestion, day: day)
                }
            } header: {
                Text("Detected by the motion sensor")
            } footer: {
                Text("Not logged yet. ✓ adds it, ✕ hides it, tap the row to adjust it first.")
            }
        } else if let hint {
            Section {
                Label(hint, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var hint: String? {
        switch model.permissions.motion {
        case .unavailable:
            return String(localized: "This device cannot detect movements (no motion coprocessor).")
        case .denied, .restricted:
            return String(localized: "Allow Motion & Fitness access in the iOS Settings to get movement suggestions.")
        case .notDetermined:
            return String(localized: "Allow motion access in the Settings tab to get movement suggestions.")
        case .authorized:
            if !model.motionHistoryAvailable(for: day) {
                return String(localized: "iOS keeps motion data for 7 days, so there are no suggestions for this day.")
            }
            return nil
        }
    }
}

struct SuggestionRow: View {
    @Environment(AppModel.self) private var model
    let suggestion: Suggestion
    let day: Date

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: suggestion.activity.symbolName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(suggestion.activity.color)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(suggestion.activity.color, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                model.accept(suggestion)
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Add")

            Button {
                model.dismiss(suggestion)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Hide")
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.open(suggestion)
        }
    }

    private var title: String {
        if suggestion.activity == .automotive {
            return String(localized: "Vehicle – which one?")
        }
        let name = suggestion.activity.suggestedMovementType?.displayName ?? suggestion.activity.displayName
        return suggestion.isOngoing ? L10n.format("%@ (ongoing)", name) : name
    }

    private var subtitle: String {
        let range = Formatting.range(start: suggestion.start, end: suggestion.isOngoing ? nil : suggestion.end, on: day)
        return "\(range) · \(DurationText.short(suggestion.duration))"
    }
}
