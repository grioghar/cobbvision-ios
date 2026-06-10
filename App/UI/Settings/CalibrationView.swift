import SwiftUI
import CVCore
import CVTelemetry

/// Two-step mounting calibration:
///  1. capture gravity while the car sits still (defines "up")
///  2. capture a short straight-line acceleration (defines "forward")
struct CalibrationView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    private enum Step {
        case intro, level, forward, done, failed
    }

    @State private var step: Step = .intro
    @State private var capture = CalibrationCapture()
    @State private var sampleTask: Task<Void, Never>?
    @State private var progress = 0.0

    var body: some View {
        VStack(spacing: 24) {
            switch step {
            case .intro:
                instruction(
                    icon: "iphone.gen3",
                    title: "Mount your phone",
                    text: "Put the phone in its mount exactly as you'll drive with it, then park on level ground."
                )
                Button("Start calibration") { runLevelCapture() }
                    .buttonStyle(.borderedProminent)

            case .level:
                instruction(
                    icon: "car.side",
                    title: "Hold still",
                    text: "Keep the car stopped — capturing the mount angle…"
                )
                ProgressView(value: progress)

            case .forward:
                instruction(
                    icon: "arrow.up.right.circle",
                    title: "Accelerate gently",
                    text: "Drive straight ahead and accelerate briskly for a few seconds (a normal pull away from a stop works)."
                )
                ProgressView(value: progress)

            case .done:
                instruction(
                    icon: "checkmark.circle.fill",
                    title: "Calibrated",
                    text: "G-forces now read in the vehicle's frame: +longitudinal is acceleration, +lateral is a right turn."
                )
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)

            case .failed:
                instruction(
                    icon: "exclamationmark.triangle",
                    title: "Couldn't calibrate",
                    text: "Not enough motion was captured. Make sure the phone is firmly mounted and try again."
                )
                Button("Retry") { step = .intro }
                    .buttonStyle(.bordered)
            }
            Spacer()
        }
        .padding()
        .navigationTitle("Mount Calibration")
        .onDisappear { sampleTask?.cancel() }
    }

    private func instruction(icon: String, title: String, text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 48))
            Text(title).font(.title2.bold())
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 40)
    }

    private func runLevelCapture() {
        step = .level
        progress = 0
        capture = CalibrationCapture()
        sampleTask = Task {
            let samples = env.motionSource.samples(hz: 50)
            let target = 150 // 3 s at 50 Hz
            for await sample in samples {
                guard !Task.isCancelled else { return }
                capture.addLevelSample(sample)
                progress = Double(capture.levelSampleCount) / Double(target)
                if capture.levelSampleCount >= target { break }
            }
            runForwardCapture()
        }
    }

    private func runForwardCapture() {
        step = .forward
        progress = 0
        sampleTask = Task {
            let samples = env.motionSource.samples(hz: 50)
            let target = 100 // ~2 s of meaningful acceleration
            for await sample in samples {
                guard !Task.isCancelled else { return }
                capture.addForwardSample(sample)
                progress = Double(capture.forwardSampleCount) / Double(target)
                if capture.forwardSampleCount >= target { break }
            }
            if let calibration = capture.build() {
                Task { await env.saveCalibration(calibration) }
                step = .done
            } else {
                step = .failed
            }
        }
    }
}
