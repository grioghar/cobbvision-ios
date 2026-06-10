import SwiftUI
import CVCore

struct ActiveSessionView: View {
    @EnvironmentObject private var env: AppEnvironment
    let info: ActiveSessionInfo

    var body: some View {
        VStack(spacing: 16) {
            statusHeader

            CameraPreviewStack()
                .frame(height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            GForceGaugeView()
                .frame(height: 200)

            statsGrid

            if !info.externalCams.isEmpty {
                externalCamsRow
            }

            Button {
                Task { await env.sessionManager.stop() }
            } label: {
                Label("Stop Session", systemImage: "stop.circle.fill")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 12) {
            if info.recording {
                Label("REC", systemImage: "record.circle.fill")
                    .foregroundStyle(.red)
            }
            if info.streaming.isLive {
                Label("LIVE", systemImage: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.green)
            }
            if case .degraded(let reason) = info.streaming {
                Label(reason, systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.yellow)
                    .font(.caption)
            }
            Spacer()
            if info.thermalWarning {
                Label("Cooling", systemImage: "thermometer.high")
                    .foregroundStyle(.orange)
            }
            Text(info.startedAt, style: .timer)
                .monospacedDigit()
        }
        .font(.headline)
    }

    private var statsGrid: some View {
        Grid(horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                stat("Speed", info.speedMps.map { "\(Int($0 * 2.23694)) mph" } ?? "—")
                stat("GPS", gpsLabel)
            }
            GridRow {
                stat("Peak lat", String(format: "%.2f g", info.peakG.lateral))
                stat("Peak brake", String(format: "%.2f g", info.peakG.longitudinalBrake))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var gpsLabel: String {
        switch info.gpsFix {
        case .none: "No fix"
        case .poor: "Poor"
        case .good: "Good"
        case .excellent: "Excellent"
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit().bold())
        }
        .frame(maxWidth: .infinity)
    }

    private var externalCamsRow: some View {
        HStack(spacing: 8) {
            ForEach(info.externalCams) { cam in
                Label(cam.name, systemImage: icon(for: cam.phase))
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
                    .foregroundStyle(cam.phase == .recording ? .red : .secondary)
            }
            Spacer()
        }
    }

    private func icon(for phase: ExternalCamStatus.Phase) -> String {
        switch phase {
        case .recording: "record.circle.fill"
        case .ready: "checkmark.circle"
        case .connecting: "arrow.triangle.2.circlepath"
        case .disconnected: "bolt.slash"
        case .error: "exclamationmark.triangle"
        }
    }
}
