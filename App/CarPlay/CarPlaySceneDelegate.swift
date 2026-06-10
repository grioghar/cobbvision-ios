import CarPlay
import UIKit

/// Entry point for the CarPlay scene (Driving Task entitlement — template UI
/// only, no video). All logic lives in `CarPlayCoordinator`.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var coordinator: CarPlayCoordinator?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        let environment = (UIApplication.shared.delegate as? AppDelegate)?.environment
            ?? AppEnvironment()
        coordinator = CarPlayCoordinator(
            interfaceController: interfaceController,
            environment: environment
        )
        coordinator?.start()
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        coordinator?.stop()
        coordinator = nil
    }
}
