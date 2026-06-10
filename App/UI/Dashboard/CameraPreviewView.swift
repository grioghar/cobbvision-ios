import SwiftUI
import AVFoundation
import CVCore

/// Shows the live preview(s): full-bleed single camera, or rear full + front
/// picture-in-picture for dual sessions. The simulator (FakeCaptureEngine)
/// shows a placeholder.
struct CameraPreviewStack: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        if let engine = env.multiCamEngine {
            ZStack(alignment: .topTrailing) {
                if let rear = engine.previewLayer(for: .rear) {
                    PreviewLayerView(layer: rear)
                } else if let front = engine.previewLayer(for: .front) {
                    PreviewLayerView(layer: front)
                }
                if engine.previewLayer(for: .rear) != nil,
                   let front = engine.previewLayer(for: .front) {
                    PreviewLayerView(layer: front)
                        .frame(width: 110, height: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.6)))
                        .padding(10)
                }
            }
        } else {
            ZStack {
                Rectangle().fill(.quaternary)
                Label("Camera preview (device only)", systemImage: "camera.fill")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct PreviewLayerView: UIViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer

    final class HostView: UIView {
        var hosted: AVCaptureVideoPreviewLayer?

        override func layoutSubviews() {
            super.layoutSubviews()
            hosted?.frame = bounds
        }
    }

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        view.hosted = layer
        return view
    }

    func updateUIView(_ uiView: HostView, context: Context) {
        if layer.superlayer !== uiView.layer {
            layer.removeFromSuperlayer()
            uiView.layer.addSublayer(layer)
            uiView.hosted = layer
        }
        layer.frame = uiView.bounds
    }
}
