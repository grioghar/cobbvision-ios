import SwiftUI
import CVCore

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var env = env
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Signed in as", value: env.user?.email ?? "—")
                    Picker("Vehicle", selection: $env.selectedVehicleID) {
                        Text("None").tag(Optional<String>.none)
                        ForEach(env.vehicles) { vehicle in
                            Text(vehicle.displayName).tag(Optional(vehicle.id))
                        }
                    }
                    Button("Refresh from server") {
                        Task { await env.refreshFromServer() }
                    }
                } header: {
                    Text("Account")
                } footer: {
                    Text("GPS tracks upload against the selected vehicle and correlate with its datalogs.")
                }

                Section("Streaming") {
                    NavigationLink("Stream destinations") {
                        StreamDestinationsView()
                    }
                }

                Section {
                    NavigationLink("Calibrate phone mount") {
                        CalibrationView()
                    }
                } header: {
                    Text("G-force")
                } footer: {
                    Text("Calibrate once per mounting position so lateral/longitudinal g read in the vehicle's frame.")
                }

                Section {
                    Button("Sign out", role: .destructive) {
                        Task { await env.logout() }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("CobbVision iOS \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                        Text("Controlplane: cobbvision.grio.co")
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
