import SwiftUI

/// Shown immediately after a session ends — lets the user pick a vehicle and upload.
struct UploadSheet: View {
    @EnvironmentObject var sessionStore: SessionStore
    @Environment(\.dismiss) var dismiss

    let session: DriveSession

    @State private var vehicles:        [APIClient.Vehicle] = []
    @State private var selectedVehicle: APIClient.Vehicle?
    @State private var isUploading    = false
    @State private var uploadError:   String?
    @State private var uploaded       = false

    var body: some View {
        NavigationView {
            Form {
                Section("Session summary") {
                    LabeledContent("Duration",   value: formattedDuration)
                    LabeledContent("GPS points", value: "\(session.pointCount)")
                    LabeledContent("Started",    value: session.startedAt.formatted())
                }

                Section("Vehicle") {
                    if vehicles.isEmpty {
                        ProgressView("Loading vehicles…")
                    } else {
                        Picker("Select vehicle", selection: $selectedVehicle) {
                            Text("— Choose —").tag(Optional<APIClient.Vehicle>(nil))
                            ForEach(vehicles) { v in
                                Text("\(v.year) \(v.make) \(v.model)")
                                    .tag(Optional(v))
                            }
                        }
                    }
                }

                if let err = uploadError {
                    Section {
                        Text(err).foregroundColor(.red)
                    }
                }

                Section {
                    Button(action: upload) {
                        if isUploading {
                            ProgressView()
                        } else {
                            Text(uploaded ? "✓ Uploaded" : "Upload to CobbVision")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(selectedVehicle == nil || isUploading || uploaded)
                }
            }
            .navigationTitle("Session complete")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") { dismiss() }
                }
            }
            .task { await loadVehicles() }
        }
    }

    // MARK: - Helpers

    private var formattedDuration: String {
        let t = Int(session.duration)
        return String(format: "%02d:%02d", t / 60, t % 60)
    }

    private func loadVehicles() async {
        do { vehicles = try await APIClient.fetchVehicles() }
        catch { print("[UploadSheet] load vehicles: \(error)") }
    }

    private func upload() {
        guard let v = selectedVehicle else { return }
        isUploading = true
        uploadError = nil
        Task {
            do {
                try await sessionStore.upload(session: session, vehicleId: v.id)
                await MainActor.run { uploaded = true }
                try await Task.sleep(nanoseconds: 800_000_000)
                await MainActor.run { dismiss() }
            } catch {
                await MainActor.run {
                    uploadError = error.localizedDescription
                    isUploading = false
                }
            }
        }
    }
}
