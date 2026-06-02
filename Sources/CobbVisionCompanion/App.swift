import SwiftUI

@main
struct CobbVisionCompanionApp: App {
    @StateObject private var locationManager = LocationManager()
    @StateObject private var sessionStore   = SessionStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(locationManager)
                .environmentObject(sessionStore)
        }
    }
}
