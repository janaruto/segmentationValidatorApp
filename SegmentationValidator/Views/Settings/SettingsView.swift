import CoreLocation
import SwiftUI
import UIKit
import UserNotifications

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    @State private var checkMessage: String?
    @State private var isChecking = false
    @State private var testSent = false
    @State private var confirmingDeleteAll = false

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            Form {
                Section {
                    Toggle("Movement reminders", isOn: $model.settings.remindersEnabled)
                    if model.settings.remindersEnabled {
                        Picker("Sensitivity", selection: $model.settings.sensitivity) {
                            ForEach(Sensitivity.allCases, id: \.self) { sensitivity in
                                Text(sensitivity.title).tag(sensitivity)
                            }
                        }
                        Picker("Remind me", selection: $model.settings.timing) {
                            ForEach(ReminderTiming.allCases, id: \.self) { timing in
                                Text(timing.title).tag(timing)
                            }
                        }
                    }
                } header: {
                    Text("Reminders")
                } footer: {
                    if model.settings.remindersEnabled {
                        Text(model.settings.sensitivity.explanation)
                    } else {
                        Text("You can still log segments and see detected movements in the app.")
                    }
                }

                if model.settings.remindersEnabled {
                    Section {
                        Toggle("Quiet hours", isOn: $model.settings.quietHoursEnabled)
                        if model.settings.quietHoursEnabled {
                            DatePicker("From", selection: minutes(\.quietHoursStart), displayedComponents: .hourAndMinute)
                            DatePicker("Until", selection: minutes(\.quietHoursEnd), displayedComponents: .hourAndMinute)
                        }
                    } footer: {
                        Text("No reminders during quiet hours. Movements are still detected and shown in the app.")
                    }

                    Section {
                        Toggle("Reliable background reminders", isOn: $model.settings.useLocationWakeUps)
                        if model.settings.useLocationWakeUps {
                            locationStatusRow
                        }
                    } header: {
                        Text("Background")
                    } footer: {
                        Text("iOS lets a closed app check the motion sensor only now and then, so reminders can be late. With this option iOS wakes the app whenever you move a few hundred meters (requires location access \"Always\"). Your location is never stored or sent anywhere.")
                    }
                }

                Section {
                    Toggle("Suggest stationary periods", isOn: $model.settings.suggestStationary)
                    if model.hasDismissedSuggestions {
                        Button("Show hidden suggestions again") {
                            model.resetDismissedSuggestions()
                        }
                    }
                } header: {
                    Text("Suggestions")
                }

                permissionsSection

                Section {
                    Button {
                        Task {
                            await model.sendTestReminder()
                            testSent = true
                        }
                    } label: {
                        Label("Send a test reminder", systemImage: "bell.badge")
                    }
                    if testSent {
                        Text("The reminder arrives in 5 seconds. Lock your iPhone to see it like a real one.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        Task {
                            isChecking = true
                            let outcome = await model.evaluateReminders()
                            checkMessage = outcome.message
                            isChecking = false
                        }
                    } label: {
                        HStack {
                            Label("Check for movements now", systemImage: "waveform.path.ecg")
                            if isChecking {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isChecking)
                    if let checkMessage {
                        Text(checkMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let lastCheck = model.reminderState.lastCheckAt {
                        LabeledContent("Last check") {
                            Text(lastCheck.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                } header: {
                    Text("Test")
                }

                Section {
                    LabeledContent("Logged segments", value: "\(model.book.segments.count)")
                    Button(role: .destructive) {
                        confirmingDeleteAll = true
                    } label: {
                        Label("Delete all data", systemImage: "trash")
                    }
                    .confirmationDialog(
                        "Delete all segments?",
                        isPresented: $confirmingDeleteAll,
                        titleVisibility: .visible
                    ) {
                        Button("Delete all data", role: .destructive) {
                            model.deleteAllData()
                        }
                    } message: {
                        Text("This cannot be undone. Export a CSV first if you want to keep a copy.")
                    }
                } header: {
                    Text("Data")
                }

                Section {
                    Label("No account, no server, no tracking. Everything stays on this iPhone.", systemImage: "lock.shield")
                        .font(.footnote)
                    Button("Show introduction again") {
                        model.hasCompletedOnboarding = false
                    }
                    LabeledContent("Version", value: appVersion)
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                model.refreshPermissions()
            }
        }
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        Section {
            PermissionRow(
                title: String(localized: "Motion & Fitness"),
                systemImage: "figure.walk.motion",
                state: motionState,
                request: { Task { await model.requestMotionPermission() } },
                openSettings: openAppSettings
            )
            PermissionRow(
                title: String(localized: "Notifications"),
                systemImage: "bell",
                state: notificationState,
                request: { Task { await model.requestNotificationPermission() } },
                openSettings: openAppSettings
            )
        } header: {
            Text("Permissions")
        } footer: {
            Text("Motion access detects movements, notifications deliver the reminders.")
        }
    }

    private var locationStatusRow: some View {
        PermissionRow(
            title: String(localized: "Location \"Always\""),
            systemImage: "location",
            state: locationState,
            request: { model.configureLocationWakeUps() },
            openSettings: openAppSettings
        )
    }

    private var motionState: PermissionRow.Status {
        switch model.permissions.motion {
        case .authorized: return .granted
        case .notDetermined: return .notAsked
        case .denied, .restricted: return .denied
        case .unavailable: return .unavailable
        }
    }

    private var notificationState: PermissionRow.Status {
        switch model.permissions.notifications {
        case .authorized, .provisional, .ephemeral: return .granted
        case .notDetermined: return .notAsked
        case .denied: return .denied
        @unknown default: return .notAsked
        }
    }

    private var locationState: PermissionRow.Status {
        switch model.permissions.location {
        case .authorizedAlways: return .granted
        case .notDetermined: return .notAsked
        case .authorizedWhenInUse: return .partial
        case .denied, .restricted: return .denied
        @unknown default: return .notAsked
        }
    }

    private func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
    }

    private func minutes(_ keyPath: WritableKeyPath<DetectionSettings, Int>) -> Binding<Date> {
        Binding(
            get: {
                let value = model.settings[keyPath: keyPath]
                return Calendar.current.date(bySettingHour: value / 60, minute: value % 60, second: 0, of: .now) ?? .now
            },
            set: { date in
                model.settings[keyPath: keyPath] = Calendar.current.minutesAfterMidnight(of: date)
            }
        )
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

struct PermissionRow: View {
    enum Status {
        case granted
        case partial
        case notAsked
        case denied
        case unavailable
    }

    let title: String
    let systemImage: String
    let state: Status
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            switch state {
            case .granted:
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.green)
                    .accessibilityLabel("Allowed")
            case .notAsked:
                Button("Allow", action: request)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            case .partial:
                Button("Change", action: openSettings)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            case .denied:
                Button("Open Settings", action: openSettings)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            case .unavailable:
                Text("Not available")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
