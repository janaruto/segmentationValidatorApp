import SwiftUI

@main
struct SegmentationValidatorApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(AppModel.shared)
        }
        .onChange(of: scenePhase) { _, phase in
            AppModel.shared.scenePhaseChanged(phase)
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.taskIdentifier)) {
            await AppModel.runBackgroundRefresh()
        }
    }
}
