import Combine
import CoreDomain
import CoreRouting
import Foundation

/// Live dashboard state, driven by the shared telemetry repository.
@Observable
@MainActor
final class DashboardViewModel {

    private(set) var telemetry = VehicleTelemetry()
    private(set) var connectionState: ObdConnectionState = .disconnected
    private(set) var vehicleName = "E-GMP"
    private(set) var unitSystem: UnitSystem = .metric
    private(set) var thermalTip: String?

    /// The AI button only appears when Pro, a key, and the toggle all line up —
    /// same gate as the Android build.
    private(set) var canUseCopilot = false

    private let thermalAdvisor = ThermalAdvisor()
    private var cancellables = Set<AnyCancellable>()

    init(services: AppServices) {
        services.telemetry.state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sample in
                guard let self else { return }
                self.telemetry = sample
                self.thermalTip = self.thermalAdvisor.evaluate(telemetry: sample)
            }
            .store(in: &cancellables)

        services.telemetry.connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.connectionState = $0 }
            .store(in: &cancellables)

        services.preferences.preferences
            .combineLatest(services.entitlement.isPro)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] prefs, isPro in
                guard let self else { return }
                self.vehicleName = Ioniq5Constants.vehicleNameFor(prefs.activeProfileId)
                self.unitSystem = prefs.unitSystem
                self.canUseCopilot = isPro
                    && prefs.aiCoachingEnabled
                    && !(prefs.geminiApiKey ?? "").isEmpty
            }
            .store(in: &cancellables)
    }

    // MARK: - Derived display values

    /// Display SOC preferred; BMS SOC is the raw pack value and reads a few
    /// percent lower, so it belongs in the stat row rather than the ring.
    var socPercent: Float? { telemetry.socDisplay ?? telemetry.socBms }

    var packTempC: Int? {
        guard !telemetry.moduleTempsC.isEmpty else { return nil }
        return telemetry.moduleTempsC.reduce(0, +) / telemetry.moduleTempsC.count
    }

    /// Regen is power flowing back into the pack while actually moving.
    var isRegenerating: Bool {
        guard let power = telemetry.powerKw, let speed = telemetry.speedKph else { return false }
        return power < 0 && speed > 10
    }

    var hasData: Bool { connectionState == .connected }
}

// MARK: - Formatting

extension DashboardViewModel {

    /// Renders an optional measurement, falling back to an em dash so tiles keep
    /// their layout before the first sample arrives.
    static func format(_ value: Float?, unit: String, decimals: Int = 0) -> String {
        guard let value else { return "—" }
        return String(format: "%.\(decimals)f %@", value, unit)
    }

    func tirePressure(_ kpa: Float?) -> String {
        guard let kpa else { return "—" }
        return unitSystem == .imperial
            ? String(format: "%.0f", kpa * 0.145038)
            : String(format: "%.0f", kpa)
    }

    var tirePressureUnit: String { unitSystem == .imperial ? "PSI" : "kPa" }

    func temperature(_ celsius: Float?) -> String {
        guard let celsius else { return "—" }
        return unitSystem == .imperial
            ? String(format: "%.0f°F", celsius * 9 / 5 + 32)
            : String(format: "%.0f°C", celsius)
    }
}
