import CarPlay
import Combine
import CoreData
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
    private let planTemplate = CPListTemplate(title: "My Plan", sections: [])

    private var telemetry = VehicleTelemetry()
    private var connectionState: ObdConnectionState = .disconnected
    private var lastRefresh = Date.distantPast
    private var cancellables = Set<AnyCancellable>()

    /// Learned consumption from recent trip history, or nil when insufficient data.
    /// Mirrors Android Auto's learnedConsumptionKwhPer100Km in ChargerReach.kt.
    private var learnedConsumption: Float?

    /// Last batch of fetched chargers, so we can re-rank on telemetry updates
    /// without re-fetching from the API.
    private var fetchedChargers: [Charger] = []
    private var lastOrigin: LatLon?

    /// Latest active trip plan, so the plan tab can be rebuilt from the
    /// subscription without re-subscribing.
    private var lastPlan: TripPlan?

    /// First plan stop's charger id that already got a "may be full" alert.
    /// Guards against re-alerting on every poll cycle.
    private var lastAlertedStopId: String?

    /// Sparse occupancy poller — Places bills per request against the user's key.
    private var occupancyTimer: Timer?

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
            planTemplate,
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

        services.activePlan.activePlan
            .receive(on: DispatchQueue.main)
            .sink { [weak self] plan in
                guard let self else { return }
                self.lastPlan = plan
                // A cleared plan means a fresh journey; the next plan may reuse
                // the same charger, and it deserves its own alert.
                if plan == nil { self.lastAlertedStopId = nil }
                self.reloadPlan()
            }
            .store(in: &cancellables)

        startOccupancyTimer()

        Task { await loadChargers() }
    }

    func stop() {
        cancellables.removeAll()
        occupancyTimer?.invalidate()
        occupancyTimer = nil
    }

    private func onTelemetry(_ sample: VehicleTelemetry) {
        telemetry = sample
        let now = Date()
        guard now.timeIntervalSince(lastRefresh) >= Self.refreshInterval else { return }
        lastRefresh = now
        refreshStatus()
        refreshCharging()
        refreshChargers()
    }

    // MARK: - Status

    private func refreshStatus() {
        // Compute learned consumption from recent trip history (matching Android Auto)
        learnedConsumption = (try? services.tripLog.trips()).flatMap { trips in
            learnedConsumptionKwhPer100Km(trips: trips)
        }

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
        // Android Auto multi-step range calculation (ChargerReach.kt):
        //   1. Learn from trip history if enough data exists
        //   2. Adjust baseline for HVAC in extreme temperatures
        //   3. range = soc% × usableKwh / effectiveConsumption × 100
        let ambientTempC = telemetry.ambientTempC
        let consumption = effectiveConsumptionKwhPer100Km(ambientTempC: ambientTempC, learned: learnedConsumption)
        let km = estimatedRangeKm(socPercent: Double(soc), usableKwh: usableKwh, consumptionKwhPer100Km: Double(consumption))
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

        let soc = telemetry.socDisplay ?? telemetry.socBms
        let usableKwh = Ioniq5RoutingConstants.usableKwhForProfile(
            services.userPreferences.activeProfileId,
            customKwh: services.userPreferences.customUsableBatteryKwh
        )
        let ambient = telemetry.ambientTempC

        let candidates = rankChargers(
            chargers: chargers,
            origin: center,
            socPercent: soc,
            usableKwh: Float(usableKwh),
            ambientTempC: ambient,
            learnedKwhPer100Km: learnedConsumption
        )

        // Cache for re-ranking on telemetry updates
        fetchedChargers = chargers
        lastOrigin = center

        // CarPlay caps a POI template at 12 entries; sending more is dropped
        // silently, so trim to the nearest within comfort/tight bounds first.
        let visible = candidates.prefix(12)
        chargersTemplate.setPointsOfInterest(
            visible.map { CarPlayPointOfInterest.make(from: $0, origin: center) },
            selectedIndex: NSNotFound
        )
    }

    /// Re-rank cached chargers with fresh telemetry data — no API fetch needed.
    private func refreshChargers() {
        guard let origin = lastOrigin, !fetchedChargers.isEmpty else { return }
        let soc = telemetry.socDisplay ?? telemetry.socBms
        let usableKwh = Ioniq5RoutingConstants.usableKwhForProfile(
            services.userPreferences.activeProfileId,
            customKwh: services.userPreferences.customUsableBatteryKwh
        )
        let candidates = rankChargers(
            chargers: fetchedChargers,
            origin: origin,
            socPercent: soc,
            usableKwh: Float(usableKwh),
            ambientTempC: telemetry.ambientTempC,
            learnedKwhPer100Km: learnedConsumption
        )
        let visible = candidates.prefix(12)
        chargersTemplate.setPointsOfInterest(
            visible.map { CarPlayPointOfInterest.make(from: $0, origin: origin) },
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

    // MARK: - Plan

    private func reloadPlan() {
        guard let plan = lastPlan else {
            let placeholder = CPListItem(text: "Plan a trip on your phone", detailText: nil)
            placeholder.isEnabled = false
            planTemplate.updateSections([CPListSection(items: [placeholder])])
            return
        }

        var items: [CPListItem] = []
        for (index, stop) in plan.stops.enumerated() {
            let item = CPListItem(
                text: "\(index + 1). \(stop.charger.name)",
                detailText: String(
                    format: "%.1f km away · arrive %.0f%% · charge %d min · depart %.0f%%",
                    stop.distanceFromOriginKm,
                    stop.arrivalSoc,
                    stop.chargeMinutes,
                    stop.departureSoc
                )
            )
            // Same as trips: nothing actionable while driving.
            item.isEnabled = false
            items.append(item)
        }
        let destination = CPListItem(
            text: "Destination",
            detailText: String(format: "%.1f km", plan.totalDistanceKm)
        )
        destination.isEnabled = false
        items.append(destination)

        planTemplate.updateSections([CPListSection(items: items)])
    }

    // MARK: - Occupancy

    /// Polls the first plan stop's surroundings every few minutes. Places bills
    /// per request against the user's own key, so this stays sparse — once every
    /// 4 minutes, and the check itself no-ops without a plan or an API key.
    private func startOccupancyTimer() {
        occupancyTimer = Timer.scheduledTimer(withTimeInterval: 4 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkOccupancy()
            }
        }
    }

    private func checkOccupancy() {
        // Per-drive opt-in from the phone's drive-start prompt. Without it this
        // poller stays silent: no Places calls (billed to the user's key), no
        // alerts, even with a plan and a key in place.
        guard services.activePlan.currentOccupancyTrackingEnabled else { return }
        guard let plan = lastPlan,
              let first = plan.stops.first,
              let apiKey = services.userPreferences.googleMapsApiKey,
              !apiKey.isEmpty else { return }
        guard first.charger.id != lastAlertedStopId else { return }

        Task { [weak self] in
            guard let self else { return }
            guard let snapshot = try? await self.services.occupancy.occupancyNear(
                LatLon(lat: first.charger.lat, lon: first.charger.lon),
                radiusM: 800,
                apiKey: apiKey
            ), snapshot.allOccupied else { return }

            self.lastAlertedStopId = first.charger.id
            let distance = String(format: "%.1f km", first.distanceFromOriginKm)
            let alert = CPAlertTemplate(
                titleVariants: [
                    "Charger may be full",
                    "\(first.charger.name) is \(distance) away and nearby stations are occupied."
                ],
                actions: [CPAlertAction(title: "OK", style: .default, handler: { [weak self] _ in
                    self?.interfaceController.dismissTemplate(animated: true, completion: nil)
                })]
            )
            try? await self.interfaceController.presentTemplate(alert, animated: true)
        }
    }

    // MARK: - Formatting

    private func format(_ value: Float?, _ unit: String, decimals: Int) -> String {
        guard let value else { return "—" }
        return String(format: "%.\(decimals)f %@", value, unit)
    }
}

// MARK: - Helpers

// MARK: - Range calculation helpers
//
// Mirrors Android Auto's ChargerReach.kt — same constants, same multi-step
// estimation: learn from trip history, adjust for HVAC, compute range.

/// Baseline consumption matching the Android Auto dashboard range tile.
private let baseConsumptionKwhPer100Km: Float = 19

/// Straight-line distance under-reads by ~1.3× on mixed road networks.
/// Kept as a constant even though CarPlay doesn't use it directly, so the
/// consumption logic stays identical to the Android source.
private let roadDetourFactor: Float = 1.3

/// Speed assumed when converting HVAC draw (W) into kWh/100 km.
private let assumedSpeedKph: Float = 60

/// HVAC load already inside `baseConsumptionKwhPer100Km` (19 kWh/100 km at 20°C).
private let baselineHvacW: Double = hvacPowerW(ambientC: 20)

/// Driving distance required before the driver's own efficiency is trusted.
private let learnedConsumptionMinKm: Float = 50

/// How far back trip history is drawn from for the learned figure (60 days).
private let learnedConsumptionWindow: TimeInterval = 60 * 24 * 60 * 60

/// Sanity band for a learned figure.
private let plausibleConsumptionRange: ClosedRange<Float> = 8...40

/// The driver's own recent consumption from logged trip history, or nil
/// when there is not enough data.
/// Mirrors Android's `learnedConsumptionKwhPer100Km()` in ChargerReach.kt.
private func learnedConsumptionKwhPer100Km(trips: [TripEntity]) -> Float? {
    let cutoff = Date().addingTimeInterval(-learnedConsumptionWindow)
    let recent = trips.filter { $0.startTime >= cutoff && $0.endTime != nil }
    let distanceKm = recent.reduce(0) { $0 + $1.distanceKm }
    let energyKwh = recent.reduce(0) { $0 + $1.energyUsedKwh }
    guard distanceKm >= learnedConsumptionMinKm, energyKwh > 0 else { return nil }
    let consumption = (energyKwh / distanceKm * 100)
    return plausibleConsumptionRange.contains(consumption) ? consumption : nil
}

/// Effective consumption for current conditions. Learned data wins outright
/// (it already includes real HVAC draw); otherwise the baseline is adjusted
/// for extreme temperatures.
/// Mirrors Android's `effectiveConsumptionKwhPer100Km()` in ChargerReach.kt.
private func effectiveConsumptionKwhPer100Km(
    ambientTempC: Int?,
    learned: Float?
) -> Float {
    if let learned { return learned }
    guard let ambientTempC else { return baseConsumptionKwhPer100Km }
    let excessHvacW = max(hvacPowerW(ambientC: Float(ambientTempC)) - baselineHvacW, 0)
    let hvacKwhPer100Km = Float((excessHvacW / 1000) / Double(assumedSpeedKph) * 100)
    return baseConsumptionKwhPer100Km + hvacKwhPer100Km
}

/// Range remaining at `socPercent` of a `usableKwh` pack, in km.
/// Mirrors Android's `estimatedRangeKm()` in ChargerReach.kt.
private func estimatedRangeKm(
    socPercent: Double,
    usableKwh: Double,
    consumptionKwhPer100Km: Double
) -> Double {
    guard consumptionKwhPer100Km > 0 else { return 0 }
    return socPercent / 100 * usableKwh / consumptionKwhPer100Km * 100
}

// MARK: - Charger reachability
//
// Mirrors Android Auto's ChargerReach.kt — ranks chargers by whether the
// current charge can actually reach them.

/// How comfortably a charger can be reached on the current charge.
enum Reach: Comparable {
    case comfortable
    case tight
    case outOfRange
    case unknown
}

/// A charger with estimated reachability data.
struct ChargerCandidate {
    let charger: Charger
    let straightLineKm: Double
    let driveKm: Double
    let arrivalSoc: Float?
    let reach: Reach

    var isUltraFast: Bool { charger.maxPowerKw >= ultraFastKw }
}

private let ultraFastKw: Float = 150
private let comfortReserveSoc: Float = 10
private let searchRadiusKm: Double = 30

/// SOC-aware ranking of nearby chargers.
/// Mirrors Android's `rankChargers()` in ChargerReach.kt.
private func rankChargers(
    chargers: [Charger],
    origin: LatLon,
    socPercent: Float?,
    usableKwh: Float,
    ambientTempC: Int? = nil,
    learnedKwhPer100Km: Float? = nil
) -> [ChargerCandidate] {
    let consumption = effectiveConsumptionKwhPer100Km(ambientTempC: ambientTempC, learned: learnedKwhPer100Km)

    return chargers
        .map { charger in
            let straightLineKm = approxDistanceKm(origin, LatLon(lat: charger.lat, lon: charger.lon))
            let driveKm = straightLineKm * Double(roadDetourFactor)
            let arrivalSoc = socPercent.map { soc -> Float in
                let kwhNeeded = Float(driveKm / 100.0) * consumption
                return soc - (kwhNeeded / usableKwh * 100)
            }
            return ChargerCandidate(
                charger: charger,
                straightLineKm: straightLineKm,
                driveKm: driveKm,
                arrivalSoc: arrivalSoc,
                reach: arrivalSoc.map { $0 >= comfortReserveSoc ? .comfortable : $0 > 0 ? .tight : .outOfRange } ?? .unknown
            )
        }
        .sorted { a, b in
            if a.reach != b.reach { return a.reach < b.reach }
            return a.straightLineKm < b.straightLineKm
        }
}

/// Equirectangular approximation — accurate well past the ~10 km radius this
/// screen queries, and cheap enough to run per charger on every invalidate.
/// Mirrors Android's `approxDistanceKm()` in ChargerReach.kt.
private func approxDistanceKm(_ a: LatLon, _ b: LatLon) -> Double {
    let dLat = (a.lat - b.lat) * 111.0
    let dLon = (a.lon - b.lon) * 111.0 * cos((a.lat + b.lat) / 2 * .pi / 180)
    return sqrt(dLat * dLat + dLon * dLon)
}

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
