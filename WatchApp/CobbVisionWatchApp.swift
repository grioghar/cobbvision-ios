import SwiftUI

@main
struct CobbVisionWatchApp: App {
    @State private var model = WatchSessionModel()

    var body: some Scene {
        WindowGroup {
            WatchDashboardView()
                .environment(model)
                .onAppear { model.activate() }
        }
    }
}
