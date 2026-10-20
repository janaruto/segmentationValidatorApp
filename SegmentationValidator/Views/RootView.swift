import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        TabView(selection: $model.selectedTab) {
            DayView()
                .tabItem {
                    Label("Day", systemImage: "calendar.day.timeline.left")
                }
                .tag(AppTab.day)
            HistoryView()
                .tabItem {
                    Label("History", systemImage: "calendar")
                }
                .tag(AppTab.history)
            ExportView()
                .tabItem {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .tag(AppTab.export)
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(AppTab.settings)
        }
        .tint(Color.brand)
        .sheet(item: $model.sheet) { sheet in
            Group {
                switch sheet {
                case .editor(let request):
                    SegmentEditorSheet(request: request)
                case .datePicker:
                    DatePickerSheet()
                case .movingAnswer(let answer):
                    MovingAnswerSheet(answer: answer)
                case .locationMap(let day):
                    LocationMapSheet(day: day)
                }
            }
            .tint(Color.brand)
        }
        .fullScreenCover(isPresented: onboardingBinding) {
            OnboardingView()
                .tint(Color.brand)
        }
        .alert(model.alert?.title ?? "", isPresented: alertBinding, presenting: model.alert) { _ in
            Button("OK", role: .cancel) {}
        } message: { alert in
            Text(alert.message)
        }
    }

    private var onboardingBinding: Binding<Bool> {
        Binding(
            get: { !model.hasCompletedOnboarding },
            set: { isPresented in
                if !isPresented {
                    model.hasCompletedOnboarding = true
                }
            }
        )
    }

    /// Only used while no sheet is open; the editor shows alerts itself.
    private var alertBinding: Binding<Bool> {
        Binding(
            get: { model.alert != nil && model.sheet == nil },
            set: { isPresented in
                if !isPresented {
                    model.alert = nil
                }
            }
        )
    }
}
