import SwiftUI
import CVCore
import CVExternalCam

struct ExternalCamerasView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var statuses: [ExternalCamStatus] = []
    @State private var discovered: [GoProScanner.Discovered] = []
    @State private var scanning = false
    @State private var scanTask: Task<Void, Never>?
    @State private var busyIDs: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                Section("Connected") {
                    if statuses.isEmpty {
                        Text("No cameras connected.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(statuses) { status in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(status.name)
                                Text(label(for: status))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            phaseIcon(status.phase)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                Task {
                                    await env.externalCameras.unregister(id: status.id)
                                    await reload()
                                }
                            } label: {
                                Label("Forget", systemImage: "trash")
                            }
                        }
                    }
                }

                Section("Add a GoPro") {
                    if scanning {
                        ForEach(discovered) { found in
                            Button {
                                pair(found)
                            } label: {
                                HStack {
                                    Label(found.name, systemImage: "camera")
                                    Spacer()
                                    if busyIDs.contains(found.id.uuidString) {
                                        ProgressView()
                                    }
                                }
                            }
                            .disabled(busyIDs.contains(found.id.uuidString))
                        }
                        if discovered.isEmpty {
                            HStack {
                                ProgressView()
                                Text("Scanning… put the GoPro in pairing mode (Preferences → Wireless Connections).")
                                    .font(.caption)
                            }
                        }
                        Button("Stop scanning") { stopScan() }
                    } else {
                        Button {
                            startScan()
                        } label: {
                            Label("Scan for GoPros", systemImage: "magnifyingglass")
                        }
                    }
                }

                Section {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Insta360")
                            Text("SDK access pending — control coming soon.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "hourglass").foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Connected cameras start and stop with your sessions (configurable per preset). Control is Bluetooth-only while streaming over WiFi, so the phone keeps its internet connection.")
                }
            }
            .navigationTitle("Cameras")
            .task {
                await reload()
            }
            .refreshable { await reload() }
        }
    }

    private func label(for status: ExternalCamStatus) -> String {
        if let detail = status.detail { return detail }
        return switch status.phase {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting…"
        case .ready: "Ready"
        case .recording: "Recording"
        case .error: "Error"
        }
    }

    @ViewBuilder
    private func phaseIcon(_ phase: ExternalCamStatus.Phase) -> some View {
        switch phase {
        case .recording: Image(systemName: "record.circle.fill").foregroundStyle(.red)
        case .ready: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .connecting: ProgressView()
        case .disconnected: Image(systemName: "bolt.slash").foregroundStyle(.secondary)
        case .error: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        }
    }

    private func reload() async {
        statuses = await env.externalCameras.statuses()
    }

    private func startScan() {
        scanning = true
        discovered = []
        scanTask = Task {
            for await found in env.goProScanner.discoveries() {
                if !discovered.contains(where: { $0.id == found.id }) {
                    discovered.append(found)
                }
            }
        }
    }

    private func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        scanning = false
    }

    private func pair(_ found: GoProScanner.Discovered) {
        guard let controller = env.goProScanner.makeController(for: found) else { return }
        busyIDs.insert(found.id.uuidString)
        Task {
            defer { busyIDs.remove(found.id.uuidString) }
            do {
                try await controller.connect()
                await env.externalCameras.register(controller)
                stopScan()
                await reload()
            } catch {
                // Status row shows the failure on next reload.
                await reload()
            }
        }
    }
}
