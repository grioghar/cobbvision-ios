import SwiftUI

@main
struct CobbVisionWatchApp: App {
    @StateObject private var model = WatchSessionModel()

    var body: some Scene {
        WindowGroup {
            WatchDashboardView()
                .environmentObject(model)
                .onAppear { model.activate() }
        }
    }
}
