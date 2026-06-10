import SwiftUI

struct RootView: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        if env.isLoggedIn {
            MainTabView()
        } else {
            LoginView()
        }
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("Drive", systemImage: "gauge.open.with.lines.needle.33percent") }
            PresetListView()
                .tabItem { Label("Presets", systemImage: "slider.horizontal.3") }
            SessionHistoryView()
                .tabItem { Label("Sessions", systemImage: "clock.arrow.circlepath") }
            ExternalCamerasView()
                .tabItem { Label("Cameras", systemImage: "web.camera") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
