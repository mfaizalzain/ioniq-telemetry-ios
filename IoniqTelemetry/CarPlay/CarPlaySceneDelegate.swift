import CarPlay
import CoreDomain

/// CarPlay scene entry point.
///
/// Reads `AppServices.shared` rather than building its own stack: the phone app
/// and the car must share one adapter connection, and a second `ObdManager` would
/// fight the first for the same BLE peripheral.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    private var coordinator: CarPlayCoordinator?

    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        Task { @MainActor in
            let services = AppServices.shared
            await services.initialize()
            let coordinator = CarPlayCoordinator(
                interfaceController: interfaceController,
                services: services
            )
            self.coordinator = coordinator
            coordinator.start()
        }
    }

    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        Task { @MainActor in
            coordinator?.stop()
            coordinator = nil
        }
    }
}
