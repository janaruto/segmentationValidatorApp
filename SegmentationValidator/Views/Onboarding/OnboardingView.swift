import SwiftUI

/// First start: explains the app and asks for the permissions it needs.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                welcomePage.tag(0)
                remindersPage.tag(1)
                backgroundPage.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(index == page ? Color.brand : Color.secondary.opacity(0.3))
                        .frame(width: index == page ? 22 : 8, height: 8)
                }
            }
            .animation(.snappy, value: page)
            .padding(.top, 8)
            .accessibilityHidden(true)

            Button {
                if page < 2 {
                    withAnimation {
                        page += 1
                    }
                } else {
                    model.hasCompletedOnboarding = true
                }
            } label: {
                Text(page < 2 ? "Continue" : "Start logging")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding()
        }
        .onAppear {
            model.refreshPermissions()
        }
    }

    private var welcomePage: some View {
        OnboardingPage(
            systemImage: "calendar.day.timeline.left",
            title: "Log your day in segments",
            text: "For every part of your day note when it started, when it ended and how you moved: stationary, walking, bike, bus/tram, train, car, ship, cable car or other. Export everything as CSV whenever you like."
        ) {
            Label("Your data stays on this iPhone. No account, no server, no costs.", systemImage: "lock.shield")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var remindersPage: some View {
        OnboardingPage(
            systemImage: "bell.badge",
            title: "Reminders when you move",
            text: "The motion sensor notices when you start moving and the app reminds you to log the segment, with day and times already filled in and the previous segment shown for checking."
        ) {
            VStack(spacing: 12) {
                permissionButton(
                    title: "Allow motion access",
                    isGranted: model.permissions.motion == .authorized,
                    isUnavailable: model.permissions.motion == .unavailable
                ) {
                    Task { await model.requestMotionPermission() }
                }
                permissionButton(
                    title: "Allow notifications",
                    isGranted: [.authorized, .provisional, .ephemeral].contains(model.permissions.notifications),
                    isUnavailable: false
                ) {
                    Task { await model.requestNotificationPermission() }
                }
            }
        }
    }

    private var backgroundPage: some View {
        OnboardingPage(
            systemImage: "location.circle",
            title: "Optional: location points",
            text: "Every 5 minutes the app can save a location point – GPS is only switched on for a few seconds. If you are suddenly far away from the previous point, it asks whether you are on the move; if you hardly move during a trip, it asks whether you have arrived. Just answer True or False. The points stay on this iPhone, and you can change this any time in Settings."
        ) {
            if model.settings.locationTracking {
                Label("Turned on", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Record location points") {
                    model.settings.locationTracking = true
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func permissionButton(
        title: LocalizedStringKey,
        isGranted: Bool,
        isUnavailable: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if isGranted {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if isUnavailable {
                    Text("Not available")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(isGranted || isUnavailable)
    }
}

private struct OnboardingPage<Accessory: View>: View {
    let systemImage: String
    let title: LocalizedStringKey
    let text: LocalizedStringKey
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: systemImage)
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundStyle(Color.brand.gradient)
                    .padding(.top, 48)
                Text(title)
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                Text(text)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                accessory()
                    .padding(.top, 8)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 48)
        }
    }
}
