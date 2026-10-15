import SwiftUI

/// Colored square with the movement type's symbol.
struct TypeIcon: View {
    let type: MovementType
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: type.symbolName)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(type.color.gradient)
            )
            .accessibilityHidden(true)
    }
}

/// Capsule button content used for the live logging shortcuts.
struct TypeChip: View {
    let type: MovementType
    var isHighlighted = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: type.symbolName)
            Text(type.displayName)
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .foregroundStyle(isHighlighted ? Color.white : type.color)
        .background(
            Capsule().fill(isHighlighted ? type.color : type.color.opacity(0.15))
        )
        .overlay(
            Capsule().strokeBorder(type.color.opacity(isHighlighted ? 0 : 0.35), lineWidth: 1)
        )
    }
}

/// Grid of all movement types for the editor.
struct MovementTypeGrid: View {
    @Binding var selection: MovementType?
    /// Types to emphasise, e.g. the vehicles when the phone detected "some vehicle".
    var highlighted: [MovementType] = []

    private let columns = [GridItem(.adaptive(minimum: 92), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(MovementType.allCases) { type in
                let isSelected = selection == type
                Button {
                    selection = type
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: type.symbolName)
                            .font(.title2)
                        Text(type.displayName)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .frame(maxWidth: .infinity, minHeight: 66)
                    .foregroundStyle(isSelected ? Color.white : type.color)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(isSelected ? type.color : type.color.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                type.color,
                                style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])
                            )
                            .opacity(highlighted.contains(type) && !isSelected ? 1 : 0)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(type.displayName)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.vertical, 6)
    }
}

/// Small red "running" tag.
struct RunningBadge: View {
    var body: some View {
        Text("live")
            .font(.caption2.weight(.bold))
            .textCase(.uppercase)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(.white)
            .background(Capsule().fill(Color.red))
    }
}

/// Duration of a segment; keeps ticking while it runs.
struct DurationLabel: View {
    let segment: Segment

    var body: some View {
        Group {
            if segment.isRunning {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(DurationText.short(segment.duration(now: context.date)))
                }
            } else {
                Text(DurationText.short(segment.duration(now: .now)))
            }
        }
        .font(.subheadline.monospacedDigit())
        .foregroundStyle(.secondary)
    }
}
