import SwiftUI
import CVCore

/// Friction-circle g-force gauge: live dot, fading trail, peak markers.
/// Polls `SessionManager.currentG()` at ~30 Hz while visible (the recorder
/// updates its `latestG` from 50 Hz device motion).
struct GForceGaugeView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var current: (lat: Double, lon: Double) = (0, 0)
    @State private var trail: [CGPoint] = []
    @State private var pollTask: Task<Void, Never>?

    private let maxG = 1.5

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = side / 2 - 8

            // Reference rings at 0.5 / 1.0 / 1.5 g.
            for ring in [0.5, 1.0, 1.5] {
                let r = radius * ring / maxG
                let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
                context.stroke(
                    Path(ellipseIn: rect),
                    with: .color(.gray.opacity(ring == 1.0 ? 0.5 : 0.25)),
                    lineWidth: 1
                )
                context.draw(
                    Text(String(format: "%.1f", ring)).font(.system(size: 9)).foregroundColor(.gray),
                    at: CGPoint(x: center.x + r + 2, y: center.y - 6),
                    anchor: .topLeading
                )
            }
            // Crosshairs.
            context.stroke(
                Path { p in
                    p.move(to: CGPoint(x: center.x - radius, y: center.y))
                    p.addLine(to: CGPoint(x: center.x + radius, y: center.y))
                    p.move(to: CGPoint(x: center.x, y: center.y - radius))
                    p.addLine(to: CGPoint(x: center.x, y: center.y + radius))
                },
                with: .color(.gray.opacity(0.2)),
                lineWidth: 1
            )

            func position(lat: Double, lon: Double) -> CGPoint {
                CGPoint(
                    x: center.x + radius * CGFloat(min(max(lat / maxG, -1), 1)),
                    y: center.y - radius * CGFloat(min(max(lon / maxG, -1), 1))
                )
            }

            // Trail (newest brightest). Entries are normalized g values.
            for (index, g) in trail.enumerated() {
                let point = position(lat: g.x, lon: g.y)
                let alpha = Double(index + 1) / Double(trail.count) * 0.5
                context.fill(
                    Path(ellipseIn: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)),
                    with: .color(.green.opacity(alpha))
                )
            }

            // Live dot.
            let dot = position(lat: current.lat, lon: current.lon)
            context.fill(
                Path(ellipseIn: CGRect(x: dot.x - 7, y: dot.y - 7, width: 14, height: 14)),
                with: .color(.green)
            )

            // Numeric readout.
            context.draw(
                Text(String(format: "lat %+.2f   lon %+.2f", current.lat, current.lon))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundColor(.primary),
                at: CGPoint(x: center.x, y: size.height - 8),
                anchor: .bottom
            )
        }
        .onAppear { startPolling() }
        .onDisappear { pollTask?.cancel() }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard env.sessionState.isActive else {
                    if current != (0, 0) {
                        current = (0, 0)
                        trail = []
                    }
                    continue
                }
                let g = await env.sessionManager.currentG()
                current = (g.lateral, g.longitudinal)
                // Trail bookkeeping happens in canvas coordinates next draw;
                // store normalized points so resizes don't smear.
                trail.append(CGPoint(x: g.lateral, y: g.longitudinal))
                if trail.count > 60 { trail.removeFirst(trail.count - 60) }
            }
        }
    }
}
