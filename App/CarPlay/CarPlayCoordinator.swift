import CarPlay
import UIKit
import CVCore

/// Drives the CarPlay UI from `SessionState`:
/// - idle → grid of presets (one tap starts a session)
/// - preparing/stopping → information template with the step label
/// - active → status items (REC/LIVE/GPS/speed/peak g) + Stop button
///
/// Updates are throttled to 1 Hz by the session ticker upstream.
@MainActor
final class CarPlayCoordinator {
    private let interfaceController: CPInterfaceController
    private let environment: AppEnvironment
    private var stateTask: Task<Void, Never>?
    private var lastPhaseKey = ""

    init(interfaceController: CPInterfaceController, environment: AppEnvironment) {
        self.interfaceController = interfaceController
        self.environment = environment
    }

    func start() {
        stateTask = Task { [weak self] in
            guard let self else { return }
            let updates = await self.environment.sessionManager.stateUpdates()
            for await state in updates {
                guard !Task.isCancelled else { return }
                await self.render(state)
            }
        }
    }

    func stop() {
        stateTask?.cancel()
        stateTask = nil
    }

    private func render(_ state: SessionState) async {
        switch state {
        case .idle:
            await setRoot(idleTemplate(), phaseKey: "idle")
        case .preparing(let step):
            await setRoot(progressTemplate(title: "Starting", detail: step), phaseKey: "preparing-\(step)")
        case .stopping:
            await setRoot(progressTemplate(title: "Stopping", detail: "Finishing recordings…"), phaseKey: "stopping")
        case .active(let info):
            // Replace the whole template each tick — CPInformationTemplate
            // items are immutable, and at 1 Hz this is cheap.
            await setRoot(activeTemplate(info), phaseKey: "active", force: true)
        case .failed(let error):
            await setRoot(failedTemplate(error), phaseKey: "failed")
        }
    }

    private func setRoot(_ template: CPTemplate, phaseKey: String, force: Bool = false) async {
        guard force || phaseKey != lastPhaseKey else { return }
        lastPhaseKey = phaseKey
        try? await interfaceController.setRootTemplate(template, animated: false)
    }

    // MARK: - Templates

    private func idleTemplate() -> CPTemplate {
        let presets = Array(environment.presets.prefix(8))
        let buttons = presets.map { preset in
            CPGridButton(
                titleVariants: [preset.name],
                image: UIImage(systemName: gridIcon(for: preset)) ?? UIImage()
            ) { [weak self] _ in
                guard let self else { return }
                Task {
                    await self.environment.sessionManager.start(preset: preset)
                }
            }
        }
        return CPGridTemplate(title: "CobbVision", gridButtons: buttons)
    }

    private func gridIcon(for preset: Preset) -> String {
        if preset.mode.contains(.stream) { return "dot.radiowaves.left.and.right" }
        if preset.cameras == .both { return "camera.on.rectangle" }
        return "record.circle"
    }

    private func progressTemplate(title: String, detail: String) -> CPTemplate {
        CPInformationTemplate(
            title: title,
            layout: .leading,
            items: [CPInformationItem(title: detail, detail: nil)],
            actions: []
        )
    }

    private func activeTemplate(_ info: ActiveSessionInfo) -> CPTemplate {
        var items: [CPInformationItem] = []
        items.append(CPInformationItem(
            title: info.recording ? "● Recording" : "Recording off",
            detail: info.presetName
        ))
        if info.streaming.isLive {
            items.append(CPInformationItem(title: "Live stream", detail: "On air"))
        }
        items.append(CPInformationItem(
            title: "GPS",
            detail: gpsLabel(info.gpsFix)
        ))
        if let speed = info.speedMps {
            items.append(CPInformationItem(
                title: "Speed",
                detail: "\(Int(speed * 2.23694)) mph"
            ))
        }
        items.append(CPInformationItem(
            title: "Peak g",
            detail: String(
                format: "lat %.2f · acc %.2f · brk %.2f",
                info.peakG.lateral, info.peakG.longitudinalAccel, info.peakG.longitudinalBrake
            )
        ))
        if info.thermalWarning {
            items.append(CPInformationItem(title: "⚠ Heat", detail: "Quality reduced to cool down"))
        }

        let stop = CPTextButton(title: "Stop Session", textStyle: .cancel) { [weak self] _ in
            guard let self else { return }
            Task {
                await self.environment.sessionManager.stop()
            }
        }
        return CPInformationTemplate(
            title: "Session",
            layout: .leading,
            items: items,
            actions: [stop]
        )
    }

    private func gpsLabel(_ fix: GPSFixQuality) -> String {
        switch fix {
        case .none: "No fix"
        case .poor: "Poor"
        case .good: "Good"
        case .excellent: "Excellent"
        }
    }

    private func failedTemplate(_ error: SessionError) -> CPTemplate {
        let dismiss = CPTextButton(title: "OK", textStyle: .confirm) { [weak self] _ in
            guard let self else { return }
            Task {
                await self.environment.sessionManager.acknowledgeFailure()
            }
        }
        return CPInformationTemplate(
            title: "Session failed",
            layout: .leading,
            items: [CPInformationItem(title: error.userMessage, detail: nil)],
            actions: [dismiss]
        )
    }
}
