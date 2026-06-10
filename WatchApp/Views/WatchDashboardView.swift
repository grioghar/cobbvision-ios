import SwiftUI
import CVCore

struct WatchDashboardView: View {
    @Environment(WatchSessionModel.self) private var model

    var body: some View {
        NavigationStack {
            Group {
                switch model.snapshot.phase {
                case .idle, .failed:
                    idleView
                case .preparing, .stopping:
                    ProgressView(model.snapshot.phase == .preparing ? "Starting…" : "Stopping…")
                case .active:
                    activeView
                }
            }
            .navigationTitle("CobbVision")
        }
        .onAppear { model.refresh() }
    }

    private var idleView: some View {
        List {
            if let error = model.snapshot.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            Section("Start a session") {
                if model.snapshot.presets.isEmpty {
                    Text("Open CobbVision on your iPhone once to sync presets.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.snapshot.presets) { preset in
                    Button {
                        model.start(presetID: preset.id)
                    } label: {
                        Label(preset.name, systemImage: "record.circle")
                    }
                    .disabled(model.commandInFlight)
                }
            }
        }
    }

    private var activeView: some View {
        ScrollView {
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    if model.snapshot.recording {
                        Label("REC", systemImage: "record.circle.fill")
                            .foregroundStyle(.red)
                    }
                    if model.snapshot.streamingLive {
                        Label("LIVE", systemImage: "dot.radiowaves.left.and.right")
                            .foregroundStyle(.green)
                    }
                }
                .font(.caption.bold())

                WatchGForceView(
                    lateral: model.liveG.gLateral,
                    longitudinal: model.liveG.gLongitudinal
                )
                .frame(height: 80)

                if let speed = model.liveG.speedMps {
                    Text("\(Int(speed * 2.23694)) mph")
                        .font(.title3.monospacedDigit())
                }

                Grid(horizontalSpacing: 12) {
                    GridRow {
                        peak("Lat", model.snapshot.peakG.lateral)
                        peak("Acc", model.snapshot.peakG.longitudinalAccel)
                        peak("Brk", model.snapshot.peakG.longitudinalBrake)
                    }
                }
                .font(.caption2)

                Button(role: .destructive) {
                    model.stopSession()
                } label: {
                    Label("Stop", systemImage: "stop.circle.fill")
                }
                .disabled(model.commandInFlight)
            }
            .padding(.horizontal, 4)
        }
    }

    private func peak(_ label: String, _ value: Double) -> some View {
        VStack(spacing: 1) {
            Text(label).foregroundStyle(.secondary)
            Text(String(format: "%.2f", value)).monospacedDigit()
        }
    }
}

/// Tiny friction-circle: the dot wanders with live g.
struct WatchGForceView: View {
    let lateral: Double
    let longitudinal: Double
    private let maxG = 1.2

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let radius = side / 2 - 2
            ZStack {
                Circle().stroke(.tertiary, lineWidth: 1)
                Circle().stroke(.quaternary, lineWidth: 1).scaleEffect(0.5)
                Circle()
                    .fill(.green)
                    .frame(width: 10, height: 10)
                    .position(
                        x: center.x + radius * min(max(lateral / maxG, -1), 1),
                        y: center.y - radius * min(max(longitudinal / maxG, -1), 1)
                    )
                    .animation(.linear(duration: 0.3), value: lateral)
            }
        }
    }
}
