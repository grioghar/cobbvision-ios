import SwiftUI

@main
struct CobbVisionApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appDelegate.environment)
                .preferredColorScheme(.dark)
        }
    }
}
