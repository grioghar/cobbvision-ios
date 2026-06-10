import SwiftUI
import CVCore
import CVSession

struct SessionHistoryView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var manifests: [SessionManifest] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(manifests, id: \.sessionID) { manifest in
                    SessionRow(manifest: manifest)
                        .swipeActions {
                            Button(role: .destructive) {
                                env.library.deleteSession(manifest.sessionID)
                                reload()
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            if manifest.fullyUploaded, !manifest.videos.isEmpty {
                                Button {
                                    env.library.deleteVideos(for: manifest.sessionID)
                                    reload()
                                } label: {
                                    Label("Free space", systemImage: "internaldrive")
                                }
                            }
                        }
                }
            }
            .navigationTitle("Sessions")
            .refreshable {
                await env.uploader.processPending()
                reload()
            }
            .onAppear { reload() }
            .onChange(of: env.sessionState.isActive) { _, _ in reload() }
            .onChange(of: env.uploadProgress) { _, _ in reload() }
            .overlay {
                if manifests.isEmpty {
                    ContentUnavailableView(
                        "No sessions yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Recorded sessions appear here and upload to CobbVision automatically.")
                    )
                }
            }
        }
    }

    private func reload() {
        manifests = env.library.manifests()
    }
}

private struct SessionRow: View {
    let manifest: SessionManifest

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(manifest.presetName).font(.headline)
                Spacer()
                if manifest.fullyUploaded {
                    Image(systemName: "checkmark.icloud").foregroundStyle(.green)
                } else {
                    Image(systemName: "icloud.and.arrow.up").foregroundStyle(.orange)
                }
            }
            Text(manifest.startedAt, format: .dateTime.month().day().hour().minute())
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                if !manifest.videos.isEmpty {
                    Label("\(manifest.videos.count)", systemImage: "video.fill")
                }
                if manifest.telemetryFileName != nil {
                    Label("GPS", systemImage: "location.fill")
                }
                if manifest.peakG.lateral > 0 {
                    Label(String(format: "%.2fg", manifest.peakG.lateral), systemImage: "gauge.high")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
