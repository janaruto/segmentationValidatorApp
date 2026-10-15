import SwiftUI

/// "What are you doing right now?" One tap starts a running segment, one tap ends it.
struct LiveLoggingCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let running = model.book.running {
                RunningSegmentView(segment: running)
            } else {
                StartSegmentView()
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: model.book.running?.id)
    }
}

private struct RunningSegmentView: View {
    @Environment(AppModel.self) private var model
    let segment: Segment

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                TypeIcon(type: segment.type, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(segment.type.displayName)
                            .font(.headline)
                        RunningBadge()
                    }
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        Text(L10n.format(
                            "Since %1$@ · %2$@",
                            Formatting.time(segment.start),
                            DurationText.short(segment.duration(now: context.date))
                        ))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    model.edit(segment)
                } label: {
                    Image(systemName: "pencil.circle")
                        .font(.title2)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Edit")
            }

            HStack(spacing: 10) {
                Menu {
                    ForEach(MovementType.allCases.filter { $0 != segment.type }) { type in
                        Button {
                            model.startLive(type)
                        } label: {
                            Label(type.displayName, systemImage: type.symbolName)
                        }
                    }
                } label: {
                    Label("Switch to…", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    model.stopLive()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .controlSize(.large)
        }
        .padding(.vertical, 4)
    }
}

private struct StartSegmentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What are you doing right now?")
                .font(.subheadline.weight(.semibold))
            if let detected = model.currentActivity, detected.activity != .unknown {
                Label(
                    L10n.format("Motion sensor: %@", detected.activity.displayName),
                    systemImage: "waveform.path.ecg"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(MovementType.allCases) { type in
                        Button {
                            model.startLive(type)
                        } label: {
                            TypeChip(type: type, isHighlighted: type == highlightedType)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
            Text("Tap a type to start a segment now, tap Stop when it ends.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    /// The type the motion sensor currently suggests.
    private var highlightedType: MovementType? {
        guard let detected = model.currentActivity, detected.confidence >= .medium else { return nil }
        return detected.activity.suggestedMovementType
    }
}
