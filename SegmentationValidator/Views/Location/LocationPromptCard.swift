import SwiftUI

/// The open location question at the top of today's screen: "Moving detected?" or "Stationary?".
/// The same question also arrives as a notification.
struct LocationPromptCard: View {
    @Environment(AppModel.self) private var model
    let prompt: LocationPrompt

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: prompt.kind == .moving ? "location.fill" : "mappin.and.ellipse")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Color.brand.gradient)
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(prompt.title)
                        .font(.headline)
                    Text(prompt.question(stationaryDistance: model.settings.stationaryDistance))
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    if let consequence {
                        Text(consequence)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack(spacing: 10) {
                Button {
                    model.answer(prompt, with: false)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark")
                        Text("False")
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    confirm()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                        Text("True")
                    }
                    .lineLimit(1)
                    // Without this, iOS 26 draws the symbol in the tint color (invisible here).
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        }
        .padding(.vertical, 4)
    }

    /// What happens with the running segment.
    private var consequence: String? {
        guard let running = model.book.running else { return nil }
        switch prompt.kind {
        case .moving:
            return L10n.format("Now: %1$@ since %2$@", running.type.displayName, Formatting.time(running.start))
        case .stationary:
            return L10n.format(
                "True ends %1$@ at %2$@ and starts Stationary.",
                running.type.displayName,
                Formatting.time(max(prompt.since, running.start))
            )
        }
    }

    private func confirm() {
        switch prompt.kind {
        case .moving:
            Task { await model.confirmMoving(prompt) }
        case .stationary:
            model.confirmStationary(prompt)
        }
    }
}
