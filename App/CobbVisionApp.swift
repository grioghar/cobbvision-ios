import SwiftUI

@main
struct CobbVisionApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appDelegate.environment)
                .preferredColorScheme(.dark)
        }
    }
}
