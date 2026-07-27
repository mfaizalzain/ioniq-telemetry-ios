import CarPlay
import Combine
import CoreDomain
import CoreRouting
import Foundation

/// Owns the CarPlay template stack and keeps it fed with live data.
///
/// Templates are mutated in place — `CPListItem.setDetailText`, reassigning
/// `CPInformationTemplate.items` — rather than rebuilt and re-pushed. Rebuilding
/// flickers and resets scroll position, which on a screen a driver glances at is
/// worse than showing nothing.
///
/// Refreshes are throttled: telemetry arrives at up to 2 Hz, far faster than
/// anyone can read, and every update is work done in the car's render loop.
@MainActor
final class CarPlayCoordinator {

    /// Slow enough to be readable and cheap, fast enough to feel live.
    private static let refreshInterval: TimeInterval = 2

    private let interfaceController: CPInterfaceController
    private let services: AppServices

    private let statusTemplate = CPInformationTemplate(
        title: "Vehicle",
        layout: .twoColumn,
        items: [],
        actions: []
    )
    private let chargingTemplate = CPInformationTemplate(
        title: "Charging",
        layout: .twoColumn,
        items: [],
        actions: []
    )
    private let chargersTemplate = CPPointOfInterestTemplate(
        title: "Chargers",
        pointsOfInterest: [],
        selectedIndex: NSNotFound
    )
    private let tripsTemplate = CPListTemplate(title: "Trips", sections: [])

    private var telemetry = VehicleTelemetry()
    private var connectionState: ObdConnectionState = .disconnected
    private var lastRefresh = Date.distantPast
    private var cancellables = Set<AnyCancellable>()

    init(interfaceController: CPInterfaceController, services: AppServices) {
        self.interfaceController = interfaceController
        self.services = services
    }

    // MARK: - Lifecycle

    func start() {
        let tabBar = CPTabBarTemplate(templates: [
            statusTemplate,
            chargingTemplate,
            chargersTemplate,
            tripsTemplate
        ])
        interfaceController.setRootTemplate(tabBar, animated: true, completion: nil)

        refreshStatus()
        refreshCharging()
        reloadTrips()

        services.telemetry.state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.onTelemetry($0) }
            .store(in: &cancellables)

        services.telemetry.connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                self.connectionState = state
                self.refreshStatus()
            }
            .store(in: &cancellables)

        Task { await loadChargers() }
    }

    func stop() {
        cancellables.removeAll()
    }

    private func onTelemetry(_ sample: VehicleTelemetry) {
        telemetry = sample
        let now = Date()
        guard now.timeIntervalSince(lastRefresh) >= Self.refreshInterval else { return }
        lastRefresh = now
        refreshStatus()
        refreshCharging()
    }

    // MARK: - Status

    private func refreshStatus() {
        let soc = telemetry.socDisplay ?? telemetry.socBms
        var items: [CPInformationItem] = [
            CPInformationItem(title: "Charge", detail: soc.map { String(format: "%.0f%%", $0) } ?? "—"),
            CPInformationItem(title: "Range", detail: estimatedRangeText),
            CPInformationItem(title: "Power", detail: format(telemetry.powerKw, "kW", decimals: 1)),
            CPInformationItem(title: "Battery health", detail: format(telemetry.soh, "%", decimals: 0)),
            CPInformationItem(title: "Pack temp", detail: packTempText),
            CPInformationItem(title: "Adapter", detail: ConnectionLabel.text(for: connectionState))
        ]
        if let low = lowTyres, !low.isEmpty {
            items.append(CPInformationItem(title: "Low tyre", detail: low))
        }
        // Reassigning `items` updates in place; pushing a new template would not.
        statusTemplate.items = items
    }

    private var estimatedRangeText: String {
        guard let soc = telemetry.socDisplay ?? telemetry.socBms else { return "—" }
        let usableKwh = Ioniq5RoutingConstants.usableKwhForProfile(
            services.userPreferences.activeProfileId,
            customKwh: services.userPreferences.customUsableBatteryKwh
        )
        // A nominal cruise figure — the physics model needs a route, and this is a
        // glanceable estimate rather than a planning number.
        let kwhPer100km = 19.0
        let km = usableKwh * Double(soc) / 100 / kwhPer100km * 100
        return String(format: "%.0f km", km)
    }

    private var packTempText: String {
        guard !telemetry.moduleTempsC.isEmpty else { return "—" }
        return "\(telemetry.moduleTempsC.reduce(0, +) / telemetry.moduleTempsC.count)°C"
    }

    private var lowTyres: String? {
        guard let tires = telemetry.tirePressuresKpa else { return nil }
        let low = [("FL", tires.fl), ("FR", tires.fr), ("RL", tires.rl), ("RR", tires.rr)]
            .filter { $0.1 < 220 }
        guard !low.isEmpty else { return nil }
        return low.map { "\($0.0) \(Int($0.1)) kPa" }.joined(separator: ", ")
    }

    // MARK: - Charging

    private func refreshCharging() {
        guard telemetry.isCharging else {
            chargingTemplate.items = [
                CPInformationItem(title: "Status", detail: "Not charging")
            ]
            return
        }

        let soc = telemetry.socDisplay ?? telemetry.socBms
        let power = telemetry.powerKw.map { abs($0) }
        var items = [
            CPInformationItem(title: "Status", detail: telemetry.chargeType?.rawValue ?? "Charging"),
            CPInformationItem(title: "Charge", detail: soc.map { String(format: "%.0f%%", $0) } ?? "—"),
            CPInformationItem(title: "Power", detail: format(power, "kW", decimals: 1))
        ]
        if let toEighty = timeToTarget(80) {
            items.append(CPInformationItem(title: "To 80%", detail: toEighty))
        }
        if let toFull = timeToTarget(100) {
            items.append(CPInformationItem(title: "To 100%", detail: toFull))
        }
        chargingTemplate.items = items
    }

    /// Linear extrapolation at the current rate. Deliberately simple: the real
    /// taper is in `ChargeCurve`, but a driver watching the screen wants the
    /// current rate's implication, not a model's opinion.
    private func timeToTarget(_ target: Float) -> String? {
        guard let soc = telemetry.socDisplay ?? telemetry.socBms, soc < target,
              let power = telemetry.powerKw, power > 1 else { return nil }
        let usableKwh = Ioniq5RoutingConstants.usableKwhForProfile(
            services.userPreferences.activeProfileId,
            customKwh: services.userPreferences.customUsableBatteryKwh
        )
        let kwhNeeded = usableKwh * Double(target - soc) / 100
        let minutes = Int(kwhNeeded / Double(abs(power)) * 60)
        guard minutes > 0, minutes < 24 * 60 else { return nil }
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes) min"
    }

    // MARK: - Chargers

    private func loadChargers() async {
        guard let center = await CarPlayLocation.shared.currentLocation() else { return }
        guard let chargers = try? await services.chargers.chargersNear(center: center, radiusKm: 30) else {
            return
        }
        // CarPlay caps a POI template at 12 entries; sending more is dropped
        // silently, so trim to the nearest deliberately.
        let nearest = Array(chargers.prefix(12))
        chargersTemplate.setPointsOfInterest(
            nearest.map { CarPlayPointOfInterest.make(from: $0, origin: center) },
            selectedIndex: NSNotFound
        )
    }

    // MARK: - Trips

    private func reloadTrips() {
        let trips = (try? services.tripLog.trips().prefix(20)) ?? []
        let items = trips.map { trip -> CPListItem in
            let item = CPListItem(
                text: trip.startTime.formatted(date: .abbreviated, time: .shortened),
                detailText: String(
                    format: "%.1f km · %.1f kWh",
                    trip.distanceKm,
                    trip.energyUsedKwh
                )
            )
            // No handler: a trip detail screen would be attention-heavy, and there
            // is nothing actionable on it while driving.
            item.isEnabled = false
            return item
        }
        tripsTemplate.updateSections([
            CPListSection(items: items.isEmpty ? [CPListItem(text: "No trips yet", detailText: nil)] : items)
        ])
    }

    // MARK: - Formatting

    private func format(_ value: Float?, _ unit: String, decimals: Int) -> String {
        guard let value else { return "—" }
        return String(format: "%.\(decimals)f %@", value, unit)
    }
}

// MARK: - Helpers

enum ConnectionLabel {
    static func text(for state: ObdConnectionState) -> String {
        switch state {
        case .connected: return "Connected"
        case .scanning: return "Scanning"
        case .connecting: return "Connecting"
        case .initializing: return "Starting"
        case .error: return "Error"
        case .disconnected: return "Offline"
        }
    }
}
