import SwiftUI

struct SettingsView: View {
    @AppStorage("api_base_url") private var baseURL = "https://cobbvision.com"
    @AppStorage("api_key")      private var apiKey  = ""

    @State private var showKey = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("CobbVision account"),
                        footer: Text("Find your API key on the Account page of the CobbVision web app.")) {
                    TextField("Server URL", text: $baseURL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    HStack {
                        if showKey {
                            TextField("API key", text: $apiKey)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        } else {
                            SecureField("API key", text: $apiKey)
                        }
                        Button {
                            showKey.toggle()
                        } label: {
                            Image(systemName: showKey ? "eye.slash" : "eye")
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: appVersion)
                    Link("cobbvision.com", destination: URL(string: baseURL)!)
                }
            }
            .navigationTitle("Settings")
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
