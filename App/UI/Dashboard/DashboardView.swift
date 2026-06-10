import SwiftUI
import CVCore
import CVSession

struct DashboardView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var selectedPresetID: UUID?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    switch env.sessionState {
                    case .idle:
                        idleContent
                    case .preparing(let step):
                        ProgressView(step)
                            .padding(.vertical, 60)
                    case .active(let info):
                        ActiveSessionView(info: info)
                    case .stopping:
                        ProgressView("Stopping — finishing recordings…")
                            .padding(.vertical, 60)
                    case .failed(let error):
                        failedContent(error)
                    }

                    if let progress = env.uploadProgress, progress.fraction < 1 {
                        UploadBanner(progress: progress)
                    }
                }
                .padding()
            }
            .navigationTitle("CobbVision")
            .onAppear { keepScreenAwakeIfActive() }
            .onChange(of: env.sessionState.isActive) { _ in keepScreenAwakeIfActive() }
        }
    }

    // While recording, the screen must not sleep — backgrounding stops video.
    private func keepScreenAwakeIfActive() {
        UIApplication.shared.isIdleTimerDisabled = env.sessionState.isActive
    }

    private var selectedPreset: Preset? {
        env.presets.first { $0.id == selectedPresetID } ?? env.presets.first
    }

    private var idleContent: some View {
        VStack(spacing: 16) {
            GForceGaugeView()
                .frame(height: 220)

            Picker("Preset", selection: $selectedPresetID) {
                ForEach(env.presets) { preset in
                    Text(preset.name).tag(Optional(preset.id))
                }
            }
            .pickerStyle(.menu)

            if let preset = selectedPreset {
                PresetSummaryRow(preset: preset)
            }

            Button {
                guard let preset = selectedPreset else { return }
                Task {
                    _ = await env.locationPermission.request()
                    await env.sessionManager.start(preset: preset)
                }
            } label: {
                Label("Start Session", systemImage: "record.circle")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(env.presets.isEmpty)
        }
    }

    private func failedContent(_ error: SessionError) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.yellow)
            Text(error.userMessage)
                .multilineTextAlignment(.center)
            Button("OK") {
                Task { await env.sessionManager.acknowledgeFailure() }
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 40)
    }
}

struct PresetSummaryRow: View {
    let preset: Preset

    var body: some View {
        HStack(spacing: 12) {
            badge(cameraLabel, icon: "camera.fill")
            if preset.mode.contains(.record) { badge("Record", icon: "record.circle") }
            if preset.mode.contains(.stream) { badge("Stream", icon: "dot.radiowaves.left.and.right") }
            if preset.gpsEnabled { badge("GPS", icon: "location.fill") }
            if preset.gForceEnabled { badge("g", icon: "gauge.high") }
        }
        .font(.caption)
    }

    private var cameraLabel: String {
        switch preset.cameras {
        case .front: "Front"
        case .rear: "Rear"
        case .both: "Dual"
        }
    }

    private func badge(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: Capsule())
    }
}

struct UploadBanner: View {
    let progress: PostSessionUploader.UploadProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(progress.detail, systemImage: "icloud.and.arrow.up")
                .font(.footnote)
            ProgressView(value: progress.fraction)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
