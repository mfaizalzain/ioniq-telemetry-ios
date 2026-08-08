@preconcurrency import CarPlay
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
    /// How often the range guard looks at the destination, independent of the
    /// 2 s telemetry refresh — the alert is the rare event, not the frame rate.
    private static let rangeCheckInterval: TimeInterval = 2 * 60
    /// One alert per destination, then this cooldown before the same destination
    /// can raise another. The driver has seen it; repeating it adds noise.
    private static let rangeAlertCooldown: TimeInterval = 5 * 60

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
    /// Live occupancy per charger id, fetched once per area load.
    private var lastLiveStatus: [String: CarPlayPointOfInterest.ChargerLiveStatus]?
    private var lastOrigin: LatLon?

    /// Latest active trip plan, so the plan tab can be rebuilt from the
    /// subscription without re-subscribing.
    private var lastPlan: TripPlan?

    /// True once the initial charger fetch has populated the map at least once.
    /// Range alerts before that would be judging against an empty candidate
    /// pool and could cry wolf.
    private var chargersLoaded = false

    /// First plan stop's charger id that already got a "may be full" alert.
    /// Guards against re-alerting on every poll cycle.
    private var lastAlertedStopId: String?

    /// Sparse occupancy poller — Places bills per request against the user's key.
    private var occupancyTimer: Timer?
    /// Nearby chargers and their live status are refreshed periodically while
    /// CarPlay stays connected. The list is also re-centered after the car has
    /// moved far enough that the original search area is no longer "nearby".
    private var nearbyRefreshTimer: Timer?
    private var nearbyRefreshInFlight = false
    private static let nearbyRefreshInterval: TimeInterval = 4 * 60
    private static let nearbyMoveRefreshDistanceKm = 5.0

    /// Rolling live consumption measured from OBD power and speed.
    private let consumptionEstimator = LiveConsumptionEstimator()
    /// Predicts arrival SOC from live behavior rescaled over the plan's
    /// per-leg elevation — the ABRP-style "model the road, calibrate to the
    /// driver" estimate. Rebuilt on demand so a calibration change made on the
    /// phone shows up here without a reconnect.
    private var arrivalEstimator: LiveArrivalEstimator {
        LiveArrivalEstimator(consumption: ConsumptionModel(
            calibration: CalibrationFactors(snapshot: services.userPreferences.calibration)
        ))
    }
    /// Decides whether the next destination is reachable, and which charger best
    /// extends range when it is not.
    private let rangeAdvisor = DestinationRangeAdvisor()
    private var rangeCheckTimer: Timer?
    /// Destination chosen from a charger pin. The plan's own destination takes
    /// precedence while a plan is active.
    private var poiDestination: LatLon?
    private var poiDestinationName: String?
    /// Chargers around the chosen destination, fetched once per destination so
    /// the suggestion pool covers the far end of the trip without re-billing.
    private var destinationPool: [Charger] = []
    /// In-memory cache of far-end pools keyed by rounded destination
    /// coordinate. Tapping the same charger twice reuses the pool instead of
    /// re-billing the charger API (Google Places users pay per request).
    private var destinationPoolCache: [String: [Charger]] = [:]
    /// Guards against overlapping async range checks.
    private var rangeCheckInFlight = false
    private var lastRangeAlertKey: String?
    private var lastRangeAlertAt = Date.distantPast
    /// The plan list's live-arrival row, updated in place on the telemetry tick
    /// (rebuilding the whole list every 2 s would flicker).
    private var lastPlanLiveItem: CPListItem?
    /// The plan list's destination row, updated with the remaining route
    /// distance as the driver's fresh location changes.
    private var lastPlanDestinationItem: CPListItem?
    /// Cached so the status screen and the plan row agree within a tick.
    private var lastArrivalEstimate: LiveArrival?

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
                // A new plan moves the destination; look at it immediately rather
                // than waiting out the range timer.
                self.scheduleRangeCheck()
            }
            .store(in: &cancellables)

        startOccupancyTimer()
        startNearbyRefreshTimer()
        startRangeTimer()

        refreshNearbyData()
    }

    func stop() {
        cancellables.removeAll()
        occupancyTimer?.invalidate()
        occupancyTimer = nil
        nearbyRefreshTimer?.invalidate()
        nearbyRefreshTimer = nil
        rangeCheckTimer?.invalidate()
        rangeCheckTimer = nil
    }

    private func onTelemetry(_ sample: VehicleTelemetry) {
        telemetry = sample
        // Feed the live consumption estimate on every frame — it is an EMA, so
        // the cost is trivial and a 2 s throttle would just blur the window.
        consumptionEstimator.update(sample)
        let now = Date()
        guard now.timeIntervalSince(lastRefresh) >= Self.refreshInterval else { return }
        lastRefresh = now
        refreshStatus()
        refreshCharging()
        refreshChargers()
        refreshLiveOverlay()
        refreshNearbyIfCarMoved()
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
        if let live = consumptionEstimator.kwhPer100Km {
            items.append(CPInformationItem(
                title: "Live use",
                detail: String(format: "%.1f kWh/100 km", live)
            ))
        }
        if let arrival = lastArrivalEstimate?.destination {
            var detail = String(format: "~%.0f%%", arrival.predictedArrivalSocPercent)
            if let planned = lastArrivalEstimate?.destinationPlannedSoc {
                detail += String(format: " (plan %.0f%%)", planned)
            }
            items.append(CPInformationItem(title: "Arrive", detail: detail))
        }
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

    private func loadChargers(center: LatLon) async {
        guard let chargers = try? await services.chargers.chargersForInCar(center: center) else {
            return
        }

        let liveStatus = await loadLiveStatus(for: chargers, center: center)
        fetchedChargers = chargers
        lastLiveStatus = liveStatus
        lastOrigin = center
        renderChargers(at: center)
        // The candidate pool exists now — don't wait out the range timer for
        // the first meaningful check.
        chargersLoaded = true
        scheduleRangeCheck()
    }

    /// Gets a current fix before every nearby refresh. If the car is still in the
    /// same search area, only occupancy is refreshed; moving to a new area fetches
    /// a new charger set and status snapshot around the new position.
    private func refreshNearbyData() {
        guard !nearbyRefreshInFlight else { return }
        nearbyRefreshInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.nearbyRefreshInFlight = false }
            guard let center = await CarPlayLocation.shared.currentLocation() else { return }

            let moved = self.lastOrigin.map {
                approxDistanceKm($0, center) >= Self.nearbyMoveRefreshDistanceKm
            } ?? true
            if moved || self.fetchedChargers.isEmpty {
                await self.loadChargers(center: center)
                return
            }

            // Keep the distance labels and SOC-aware ordering based on the
            // driver's current position even when the charger search area is
            // reused. The status request is still centered on this fresh fix.
            self.lastOrigin = center
            self.lastLiveStatus = await self.loadLiveStatus(
                for: self.fetchedChargers,
                center: center
            )
            self.renderChargers(at: center)
        }
    }

    private func refreshNearbyIfCarMoved() {
        guard let current = CarPlayLocation.shared.freshFix,
              let origin = lastOrigin,
              approxDistanceKm(origin, current) >= Self.nearbyMoveRefreshDistanceKm else { return }
        refreshNearbyData()
    }

    private func startNearbyRefreshTimer() {
        nearbyRefreshTimer = Timer.scheduledTimer(
            withTimeInterval: Self.nearbyRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshNearbyData() }
        }
    }

    /// Live occupancy for the listed chargers, when the requirements are met
    /// (Pro + Google key) — the same gate as the phone's Nearby Chargers list.
    /// One Places request for the whole area, matched to each charger's
    /// physical site via `ChargerStationMatching`. Returns nil when the
    /// requirements aren't met or the lookup failed — rows then carry no
    /// status, never a guess.
    private func loadLiveStatus(
        for chargers: [Charger],
        center: LatLon
    ) async -> [String: CarPlayPointOfInterest.ChargerLiveStatus]? {
        guard services.isPro,
              services.userPreferences.chargerOccupancyAlerts,
              let key = services.userPreferences.googleMapsApiKey,
              !key.isEmpty else { return nil }
        guard let statuses = try? await services.occupancy.matchedStatuses(
            for: chargers,
            center: center,
            radiusM: ChargerRepository.inCarRadiusKm * 1_000,
            apiKey: key
        ) else { return nil }

        var status: [String: CarPlayPointOfInterest.ChargerLiveStatus] = [:]
        for charger in chargers {
            guard let matched = statuses[charger.id] else { continue }
            status[charger.id] = CarPlayPointOfInterest.ChargerLiveStatus(
                available: matched.availableCount,
                total: matched.totalCount
            )
        }
        return status
    }

    /// Re-rank cached chargers with fresh telemetry data — no API fetch needed.
    private func refreshChargers() {
        guard let origin = lastOrigin, !fetchedChargers.isEmpty else { return }
        renderChargers(at: origin)
    }

    private func renderChargers(at origin: LatLon) {
        guard !fetchedChargers.isEmpty else { return }
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
            learnedKwhPer100Km: learnedConsumption,
            liveKwhPer100Km: consumptionEstimator.kwhPer100Km
        )
        // CarPlay caps a POI template at 12 entries; sending more is dropped
        // silently, so trim to the nearest within comfort/tight bounds first.
        let visible = candidates.prefix(12)
        chargersTemplate.setPointsOfInterest(
            visible.map {
                CarPlayPointOfInterest.make(
                    from: $0,
                    origin: origin,
                    onSetDestination: { [weak self] charger in
                        self?.setPoiDestination(charger)
                    }
                )
            },
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
            lastPlanLiveItem = nil
            lastPlanDestinationItem = nil
            lastArrivalEstimate = nil
            let placeholder = CPListItem(text: "Plan a trip on your phone", detailText: nil)
            placeholder.isEnabled = false
            planTemplate.updateSections([CPListSection(items: [placeholder])])
            return
        }

        // Live arrival — the estimate refreshes in place on the telemetry tick;
        // the "—" placeholder is replaced as soon as SOC, position and a
        // consumption figure all exist.
        let liveItem = CPListItem(text: "Live arrival", detailText: "—")
        liveItem.isEnabled = false
        lastPlanLiveItem = liveItem
        var items: [CPListItem] = [liveItem]
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
            detailText: remainingDistanceText(for: plan)
        )
        destination.isEnabled = false
        lastPlanDestinationItem = destination
        items.append(destination)

        planTemplate.updateSections([CPListSection(items: items)])
        refreshLiveOverlay()
    }

    // MARK: - Live range guard

    /// A destination the range guard is watching, with the road distance to it
    /// from the driver's current position.
    private struct NextDestination {
        let name: String
        let location: LatLon
        let distanceKm: Float
        /// True when this is the plan's next charging stop, not the final
        /// destination — the live estimate must slice legs to the stop.
        let isStop: Bool
    }

    /// Elevation- and behavior-aware arrival estimates for the road ahead.
    private struct LiveArrival {
        let nextStop: ArrivalEstimate?
        let destination: ArrivalEstimate?
        let nextStopName: String?
        let nextStopPlannedSoc: Float?
        let destinationPlannedSoc: Float?
        let destinationName: String
    }

    private func startRangeTimer() {
        rangeCheckTimer = Timer.scheduledTimer(
            withTimeInterval: Self.rangeCheckInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleRangeCheck()
            }
        }
    }

    /// Sets a charger pin as the range-guard destination. The plan's own
    /// destination takes precedence while a plan is active.
    @MainActor
    func setPoiDestination(_ charger: Charger) {
        poiDestination = LatLon(lat: charger.lat, lon: charger.lon)
        poiDestinationName = charger.name
        lastRangeAlertKey = nil
        lastRangeAlertAt = .distantPast
        // Judge with the near pool immediately; the far-end pool (cached or
        // freshly fetched) triggers a second, better-informed check.
        scheduleRangeCheck()
        Task {
            guard let dest = poiDestination else { return }
            let key = String(format: "%.3f,%.3f", dest.lat, dest.lon)
            if let cached = destinationPoolCache[key] {
                destinationPool = cached
                scheduleRangeCheck()
                return
            }
            // Fetch the far end once, so the suggestion pool covers chargers
            // between here and there, not just the 25 km ring already loaded.
            let pool = (try? await services.chargers.chargersNear(center: dest, radiusKm: 35)) ?? []
            destinationPoolCache[key] = pool
            destinationPool = pool
            scheduleRangeCheck()
        }
    }

    /// Fires the range check, never overlapping a check already in flight.
    private func scheduleRangeCheck() {
        guard !rangeCheckInFlight else { return }
        rangeCheckInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.rangeCheckInFlight = false }
            await self.checkRange()
        }
    }

    private func checkRange() async {
        guard let soc = telemetry.socDisplay ?? telemetry.socBms else { return }
        guard let consumption = currentConsumption else { return }
        guard let position = await CarPlayLocation.shared.currentLocation() else { return }
        guard let next = resolveNextDestination(position: position) else { return }
        guard let arrival = liveArrivalEstimate() else { return }
        // No charger data yet — the candidate pool would be empty and any
        // alert a lie. The initial load schedules its own check once it lands.
        guard chargersLoaded else { return }

        let usableKwh = Ioniq5RoutingConstants.usableKwhForProfile(
            services.userPreferences.activeProfileId,
            customKwh: services.userPreferences.customUsableBatteryKwh
        )

        // Elevation- and behavior-aware prediction for the road ahead. The
        // advisor's flat math still ranks charger candidates below, but the
        // headline number must reflect the climb ahead, not a flat average.
        let predictedArrival: Float
        if next.isStop, let stopEstimate = arrival.nextStop {
            predictedArrival = stopEstimate.predictedArrivalSocPercent
        } else if let destEstimate = arrival.destination {
            predictedArrival = destEstimate.predictedArrivalSocPercent
        } else {
            predictedArrival = soc - Float(next.distanceKm) / Float(usableKwh) * consumption * 100
        }
        guard predictedArrival < services.userPreferences.targetArrivalSocPercent else { return }

        // Candidate pool: the 25 km ring already fetched, chargers around the
        // destination, and the plan's own stops — deduplicated by id.
        var seen = Set<String>()
        var pool: [Charger] = []
        for charger in fetchedChargers + destinationPool + (lastPlan?.stops.map(\.charger) ?? []) {
            guard seen.insert(charger.id).inserted else { continue }
            pool.append(charger)
        }

        let candidates = pool
            .filter { !$0.isRestricted && $0.isOperational }
            .map { charger in
                RouteChargerCandidate(
                    charger: charger,
                    driveKm: roadDistanceKm(position, LatLon(lat: charger.lat, lon: charger.lon))
                )
            }

        // A charger that reported being full is not preferred, but it is not
        // removed either — occupancy changes, and the tie-break only demotes it.
        let availableIds = Set((lastLiveStatus ?? [:]).compactMap { key, status in
            status.isFull ? nil : key
        })

        let advice = rangeAdvisor.advise(
            currentSocPercent: soc,
            usableKwh: usableKwh,
            consumptionKwhPer100Km: Double(consumption),
            distanceToDestinationKm: Double(next.distanceKm),
            reserveSocPercent: services.userPreferences.targetArrivalSocPercent,
            packTempC: packTempC,
            availableChargerIds: availableIds,
            predictedArrivalSocPercent: predictedArrival,
            chargers: candidates
        )

        // One alert per destination, then a cooldown: the driver has seen it.
        let key = "\(next.name)|\(next.location.lat),\(next.location.lon)"
        if lastRangeAlertKey == key,
           Date().timeIntervalSince(lastRangeAlertAt) < Self.rangeAlertCooldown {
            return
        }
        lastRangeAlertKey = key
        lastRangeAlertAt = Date()

        await presentRangeAlert(
            advice: advice,
            destination: next,
            predictedArrivalSocPercent: predictedArrival
        )
    }

    /// The next destination on the active plan (first stop not yet passed, else
    /// the final destination), or the driver's chosen charger pin. Distance is
    /// route distance when a plan is active, road-scaled straight line otherwise.
    private func resolveNextDestination(position: LatLon) -> NextDestination? {
        if let plan = lastPlan {
            let routePoints = services.activePlan.currentRoutePoints
            if !routePoints.isEmpty {
                let (alongKm, _) = RouteGeo.projectOntoRoute(
                    points: routePoints,
                    lat: position.lat,
                    lon: position.lon,
                    totalKm: plan.totalDistanceKm
                )
                if let stop = plan.stops.first(where: { $0.distanceFromOriginKm > alongKm }) {
                    return NextDestination(
                        name: stop.charger.name,
                        location: LatLon(lat: stop.charger.lat, lon: stop.charger.lon),
                        distanceKm: stop.distanceFromOriginKm - alongKm,
                        isStop: true
                    )
                }
                return NextDestination(
                    name: "Destination",
                    location: plan.destination,
                    distanceKm: max(plan.totalDistanceKm - alongKm, 0),
                    isStop: false
                )
            }
        }
        guard let dest = poiDestination else { return nil }
        return NextDestination(
            name: poiDestinationName ?? "Destination",
            location: dest,
            distanceKm: Float(roadDistanceKm(position, dest)),
            isStop: false
        )
    }

    private func presentRangeAlert(
        advice: RangeAdvice,
        destination: NextDestination,
        predictedArrivalSocPercent: Float
    ) async {
        let arrival = Int(predictedArrivalSocPercent.rounded())
        let label = destination.name
        var lines: [String]
        var navigateAction: CPAlertAction?

        if let stop = advice.suggestedStop {
            let chargerName = stop.charger.name
            if stop.reachesDestination {
                lines = [
                    "\(label) is out of reach on this charge — arrive ~\(arrival)%.",
                    "Charge at \(chargerName): arrive ~\(Int(stop.arriveSocPercent))%, \(stop.chargeMinutes) min, then arrive at \(Int(stop.arriveDestinationSocPercent))%."
                ]
            } else {
                lines = [
                    "\(label) is out of reach — arrive ~\(arrival)%.",
                    "Even after \(chargerName) you'd arrive at \(Int(stop.arriveDestinationSocPercent))%. Consider another stop."
                ]
            }
            let charger = stop.charger
            navigateAction = CPAlertAction(title: "Navigate", style: .default, handler: { _ in
                Task { @MainActor in
                    MapsNavigation.navigate(
                        to: LatLon(lat: charger.lat, lon: charger.lon),
                        name: charger.name,
                        preferGoogleMaps: false
                    )
                }
            })
        } else {
            lines = [
                "\(label) is out of reach on this charge — arrive ~\(arrival)%.",
                "Nothing nearby can extend your range. Charge sooner."
            ]
        }

        var actions = navigateAction.map { [$0] } ?? []
        actions.append(CPAlertAction(title: "OK", style: .cancel, handler: { [weak self] _ in
            self?.interfaceController.dismissTemplate(animated: true, completion: nil)
        }))

        let alert = CPAlertTemplate(titleVariants: lines, actions: actions)
        _ = try? await interfaceController.presentTemplate(alert, animated: true)
    }

    /// Road distance between two points — straight line scaled by the same
    /// detour factor the charger ranking uses.
    private func roadDistanceKm(_ from: LatLon, _ to: LatLon) -> Double {
        approxDistanceKm(from, to) * Double(roadDetourFactor)
    }

    /// Consumption to predict with: live OBD measurement once the estimator has
    /// enough samples, otherwise learned history or the HVAC-adjusted baseline.
    private var currentConsumption: Float? {
        if let live = consumptionEstimator.kwhPer100Km { return live }
        return effectiveConsumptionKwhPer100Km(
            ambientTempC: telemetry.ambientTempC,
            learned: learnedConsumption
        )
    }

    /// Average pack temperature for charge-curve derating.
    private var packTempC: Float {
        guard !telemetry.moduleTempsC.isEmpty else { return 25 }
        return Float(telemetry.moduleTempsC.reduce(0, +) / telemetry.moduleTempsC.count)
    }

    /// The plan's legs from `fromAlongKm` onward, cut at the current position
    /// and optionally at a stop boundary. The first remaining leg's elevation
    /// scales with the driven fraction, matching the plan's uniform grade.
    private func remainingLegs(
        of plan: TripPlan,
        fromAlongKm: Float,
        upToKm: Float? = nil
    ) -> [RemainingLeg] {
        var legs: [RemainingLeg] = []
        var cursor: Float = 0
        var started = false
        for leg in plan.legs {
            let legEnd = cursor + leg.distanceKm
            if legEnd <= fromAlongKm {
                cursor = legEnd
                continue
            }
            if let upToKm, cursor >= upToKm { break }
            let start = started ? cursor : fromAlongKm
            let end = min(legEnd, upToKm ?? legEnd)
            let remaining = end - start
            started = true
            guard remaining > 0 else {
                cursor = legEnd
                continue
            }
            let fraction = leg.distanceKm > 0 ? remaining / leg.distanceKm : 1
            let speed = leg.driveMinutes > 0
                ? leg.distanceKm / Float(leg.driveMinutes) * 60
                : 95
            legs.append(RemainingLeg(
                distanceKm: remaining,
                elevationGainM: leg.elevationGainM * fraction,
                speedKph: speed
            ))
            cursor = legEnd
        }
        return legs
    }

    /// Elevation- and behavior-aware arrival estimate for the next stop (when
    /// one lies ahead) and the final destination, or nil when there is no
    /// destination, no SOC, no fresh position, or nothing to predict with.
    private func liveArrivalEstimate() -> LiveArrival? {
        guard let soc = telemetry.socDisplay ?? telemetry.socBms else { return nil }
        guard let position = CarPlayLocation.shared.freshFix else { return nil }

        let usableKwh = Ioniq5RoutingConstants.usableKwhForProfile(
            services.userPreferences.activeProfileId,
            customKwh: services.userPreferences.customUsableBatteryKwh
        )
        let ambient = Float(telemetry.ambientTempC ?? 20)
        let live = consumptionEstimator.kwhPer100Km
        let learned = learnedConsumption
        let baseline = effectiveConsumptionKwhPer100Km(
            ambientTempC: telemetry.ambientTempC,
            learned: nil
        )

        if let plan = lastPlan {
            let routePoints = services.activePlan.currentRoutePoints
            guard !routePoints.isEmpty else { return nil }
            let (alongKm, _) = RouteGeo.projectOntoRoute(
                points: routePoints,
                lat: position.lat,
                lon: position.lon,
                totalKm: plan.totalDistanceKm
            )
            let allRemaining = remainingLegs(of: plan, fromAlongKm: alongKm)
            guard !allRemaining.isEmpty else { return nil }

            let destination = arrivalEstimator.estimate(
                currentSocPercent: soc,
                usableKwh: usableKwh,
                remainingLegs: allRemaining,
                ambientC: ambient,
                liveKwhPer100Km: live,
                learnedKwhPer100Km: learned,
                baselineKwhPer100Km: baseline
            )

            var nextStop: ArrivalEstimate?
            var nextStopName: String?
            var nextStopPlanned: Float?
            if let stop = plan.stops.first(where: { $0.distanceFromOriginKm > alongKm }) {
                let upTo = remainingLegs(
                    of: plan,
                    fromAlongKm: alongKm,
                    upToKm: stop.distanceFromOriginKm
                )
                if !upTo.isEmpty {
                    nextStop = arrivalEstimator.estimate(
                        currentSocPercent: soc,
                        usableKwh: usableKwh,
                        remainingLegs: upTo,
                        ambientC: ambient,
                        liveKwhPer100Km: live,
                        learnedKwhPer100Km: learned,
                        baselineKwhPer100Km: baseline
                    )
                }
                nextStopName = stop.charger.name
                nextStopPlanned = stop.arrivalSoc
            }

            return LiveArrival(
                nextStop: nextStop,
                destination: destination,
                nextStopName: nextStopName,
                nextStopPlannedSoc: nextStopPlanned,
                destinationPlannedSoc: plan.arrivalSoc,
                destinationName: "Destination"
            )
        }

        // No plan: the chosen charger pin is a flat single leg — no elevation
        // data exists to do better, so the estimate is behavior-scaled only.
        guard let dest = poiDestination else { return nil }
        let distance = roadDistanceKm(position, dest)
        let flat = RemainingLeg(distanceKm: Float(distance), elevationGainM: 0, speedKph: 95)
        let estimate = arrivalEstimator.estimate(
            currentSocPercent: soc,
            usableKwh: usableKwh,
            remainingLegs: [flat],
            ambientC: ambient,
            liveKwhPer100Km: live,
            learnedKwhPer100Km: learned,
            baselineKwhPer100Km: baseline
        )
        return LiveArrival(
            nextStop: nil,
            destination: estimate,
            nextStopName: nil,
            nextStopPlannedSoc: nil,
            destinationPlannedSoc: nil,
            destinationName: poiDestinationName ?? "Destination"
        )
    }

    /// Pushes the latest estimate onto the plan list's live row and caches it
    /// for the status screen. In-place update — no list rebuild, no flicker.
    private func refreshLiveOverlay() {
        if let plan = lastPlan {
            lastPlanDestinationItem?.setDetailText(remainingDistanceText(for: plan))
        }

        let arrival = liveArrivalEstimate()
        lastArrivalEstimate = arrival

        guard let arrival, let liveItem = lastPlanLiveItem else {
            lastPlanLiveItem?.setDetailText("—")
            return
        }

        if let nextStop = arrival.nextStop, let name = arrival.nextStopName {
            var nextText = String(format: "~%.0f%%", nextStop.predictedArrivalSocPercent)
            if let planned = arrival.nextStopPlannedSoc {
                nextText += String(format: " (plan %.0f%%)", planned)
            }
            var destText = String(format: "~%.0f%%", arrival.destination?.predictedArrivalSocPercent ?? 0)
            if let planned = arrival.destinationPlannedSoc {
                destText += String(format: " (plan %.0f%%)", planned)
            }
            liveItem.setDetailText("\(name): \(nextText) · dest \(destText)")
        } else if let dest = arrival.destination {
            var detail = String(format: "~%.0f%%", dest.predictedArrivalSocPercent)
            if let planned = arrival.destinationPlannedSoc {
                detail += String(format: " (plan %.0f%%)", planned)
            }
            liveItem.setDetailText("\(arrival.destinationName): \(detail)")
        } else {
            liveItem.setDetailText("—")
        }
    }

    /// Formats the distance still left on the active route. The plan's total
    /// distance is used until a fresh CarPlay location is available.
    private func remainingDistanceText(for plan: TripPlan) -> String {
        guard let position = CarPlayLocation.shared.freshFix else {
            return String(format: "%.1f km remaining", plan.totalDistanceKm)
        }
        let routePoints = services.activePlan.currentRoutePoints
        guard !routePoints.isEmpty else {
            return String(format: "%.1f km remaining", plan.totalDistanceKm)
        }
        let (alongKm, _) = RouteGeo.projectOntoRoute(
            points: routePoints,
            lat: position.lat,
            lon: position.lon,
            totalKm: plan.totalDistanceKm
        )
        return String(format: "%.1f km remaining", max(plan.totalDistanceKm - alongKm, 0))
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
            guard let statuses = try? await self.services.occupancy.matchedStatuses(
                for: [first.charger],
                center: LatLon(lat: first.charger.lat, lon: first.charger.lon),
                radiusM: 800,
                apiKey: apiKey
            ),
            let matched = statuses[first.charger.id],
                  matched.isOccupied else { return }

            self.lastAlertedStopId = first.charger.id
            let distance = String(format: "%.1f km", first.distanceFromOriginKm)
            let alert = CPAlertTemplate(
                titleVariants: [
                    "Next stop is full",
                    "\(first.charger.name) is \(distance) away and has no available connectors."
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
    learnedKwhPer100Km: Float? = nil,
    liveKwhPer100Km: Float? = nil
) -> [ChargerCandidate] {
    // A live OBD measurement already contains this drive's real HVAC draw and
    // driving style, so it wins outright; learned history and the baseline are
    // the fallbacks for before the estimator has warmed up.
    let consumption = liveKwhPer100Km
        ?? effectiveConsumptionKwhPer100Km(ambientTempC: ambientTempC, learned: learnedKwhPer100Km)

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
