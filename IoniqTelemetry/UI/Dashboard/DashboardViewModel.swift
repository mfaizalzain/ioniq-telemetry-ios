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

    /// Regen is power flowing back into the pack. With the formula
    /// `pack_current = -(A*256+B)/10`, discharge current reads negative;
    /// regen/charge current reads positive. So positive power = energy
    /// flowing IN. The difference between regen and charging is whether the car
    /// is stationary, and for how long — `DriveMonitor` makes that call, and
    /// `ConnectedCarService` publishes its verdict as `isCharging` here.
    /// Mutually exclusive: if charging, this is always false.
    var isRegenerating: Bool {
        guard !telemetry.isCharging, let power = telemetry.powerKw else { return false }
        return power > 0
    }

    /// True when the vehicle is actively DC fast-charging, which gates the charge
    /// curve card on the dashboard.
    var isDcCharging: Bool {
        telemetry.isCharging
            && telemetry.chargeType == .dc
            && (telemetry.powerKw.map { abs($0) > 0 } ?? false)
    }

    var hasData: Bool { connectionState == .connected }

    /// True once any real sample has landed. Separates "never connected, every tile
    /// is an em dash" from "connected earlier, these are the last readings" — the
    /// two deserve very different screens.
    var hasEverReceivedData: Bool { socPercent != nil || telemetry.packVoltage != nil }

    /// How stale the readings are, for the banner shown after the adapter drops.
    var lastUpdatedText: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: telemetry.timestamp, relativeTo: Date())
    }

    // MARK: - Trip data (since-charge stats)

    /// True when trip odometer/energy data is available to show.
    var hasTripData: Bool { false }

    var tripDistanceText: String { distanceKm(nil) }
    var tripEnergyText: String { "— kWh" }
    var tripDurationText: String? { nil }
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

    // MARK: Distance & efficiency

    /// km → mi when imperial; identity otherwise.
    func distanceKm(_ km: Float?) -> String {
        guard let km else { return "—" }
        return unitSystem == .imperial
            ? String(format: "%.1f mi", km * 0.621371)
            : String(format: "%.1f km", km)
    }

    var distanceUnit: String { unitSystem == .imperial ? "mi" : "km" }

    /// kWh/100km → mi/kWh when imperial.
    func efficiency(_ kwhPer100km: Float?) -> String {
        guard let v = kwhPer100km, v > 0 else { return "—" }
        return unitSystem == .imperial
            ? String(format: "%.1f mi/kWh", 62.1371 / v)
            : String(format: "%.1f kWh/100km", v)
    }

    /// Speed in the active unit system.
    func speed(_ kph: Float?) -> String {
        guard let kph else { return "—" }
        return unitSystem == .imperial
            ? String(format: "%.0f mph", kph * 0.621371)
            : String(format: "%.0f km/h", kph)
    }

    /// Odometer in the active unit system.
    func odometer(_ km: Int?) -> String {
        guard let km else { return "—" }
        return unitSystem == .imperial
            ? String(format: "%.0f mi", Float(km) * 0.621371)
            : String(format: "%d km", km)
    }
}
