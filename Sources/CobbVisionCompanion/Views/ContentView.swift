import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            SessionView()
                .tabItem { Label("Record", systemImage: "record.circle") }

            HistoryView()
                .tabItem { Label("Sessions", systemImage: "list.bullet") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
        }
        .accentColor(.orange)
    }
}
