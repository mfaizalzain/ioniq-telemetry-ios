import Combine
import CoreData
import CoreDomain
import CoreRouting
import Foundation

/// The always-on pipeline behind a drive.
///
/// One consumer of the OBD telemetry stream drives everything that must observe it
/// in lockstep: motion state, trip boundaries, sample logging, and the alert
/// monitors. They share a single consumer deliberately — `DriveMonitor` and
/// `ParkedStateEvaluator` are explicitly not thread-safe, and running them from two
/// places would produce two disagreeing opinions about whether the car is moving.
///
/// The Android equivalent is a foreground `Service`. iOS has no such thing: what
/// keeps this alive during a drive is the CoreLocation background session in
/// `VehicleLocationProvider` plus CoreBluetooth's `bluetooth-central` mode, both
/// declared in Info.plist.
@Observable
@MainActor
final class ConnectedCarService {

    private(set) var parkedState: ParkedState = .unknown
    private(set) var isTripActive = false
    /// Independent coulomb-counted SOH, distinct from the BMS-reported figure.
    private(set) var estimatedSohPercent: Float?

    private let services: AppServices
    // Built on first use: constructing CLLocationManager/CMMotionActivityManager
    // is enough to raise permission prompts, and this service is created at launch.
    @ObservationIgnored private lazy var location = VehicleLocationProvider()
    private let notifier = AlertNotifier()

    private let driveMonitor = DriveMonitor()
    private let parkedEvaluator = ParkedStateEvaluator()
    private let replanMonitor = LiveReplanMonitor()
    private var occupancyMonitor: OccupancyAlertMonitor!
    private var chargeAlerts: ChargeAlertMonitor!
    private var tirePressure: TirePressureMonitor!
    private var healthEstimator: BatteryHealthEstimator!

    private var cancellables = Set<AnyCancellable>()
    private var isRunning = false
    private var lastTelemetry = VehicleTelemetry()

    /// Re-solves the remaining route with the driver's fitted calibration — the
    /// occupancy reroute must see the same consumption the live estimates do.
    /// Rebuilt on demand; a reroute is rare and the solver is stateless.
    private var routeReplanner: RouteReplanner {
        RouteReplanner(solver: TripSolver(consumption: ConsumptionModel(
            calibration: CalibrationFactors(snapshot: services.userPreferences.calibration)
        )))
    }

    // MARK: - Supervisor tuning

    /// How often the supervisor looks at the session. Frequent enough that a
    /// five-minute idle end lands close to its nominal time, rare enough to be
    /// invisible on battery.
    private static let supervisorTick: TimeInterval = 15
    /// No decoded frame for this long means the car's bus has gone quiet — the
    /// vehicle is asleep, or the link is up but no longer carrying anything.
    private static let framesQuiet: TimeInterval = 30
    /// Quiet this long while still nominally connected means the session is dead
    /// rather than idle. The adapter answers nothing, but nothing declares a drop,
    /// so without this the app waits for a manual disconnect that may never come.
    private static let sessionDead: TimeInterval = 120
    /// A trip whose frames stopped arriving this long ago is over, even when the
    /// app was suspended and neither the frame-driven idle end nor the supervisor
    /// got to run. Deliberately longer than `DriveMonitor.tripIdleEnd` (5 min),
    /// which keeps working while frames or supervisor ticks flow: this is the
    /// backstop for a frozen process, and 10 minutes of silence is unambiguous.
    private static let tripIdleEnd: TimeInterval = 10 * 60
    /// Reconnect backoff, mirroring Android's `RECONNECT_BACKOFF_MS`.
    private static let reconnectBackoff: [TimeInterval] = [5, 10, 30, 60]

    private var supervisor: Task<Void, Never>?
    /// When the last real decoded frame arrived. Nil until the first one.
    private var lastFrameAt: Date?
    private var reconnectAttempt = 0
    private var isReconnecting = false
    private var connectionState: ObdConnectionState = .disconnected

    init(services: AppServices) {
        self.services = services

        chargeAlerts = ChargeAlertMonitor { [weak self] threshold, soc in
            self?.postChargeAlert(threshold: threshold, soc: soc)
        }
        tirePressure = TirePressureMonitor { [weak self] low in
            self?.postTireAlert(low)
        }
        occupancyMonitor = OccupancyAlertMonitor(
            availabilityNear: { [occupancy = services.occupancy] charger, radius, key in
                guard let snapshot = try? await occupancy.occupancyNear(
                    LatLon(lat: charger.lat, lon: charger.lon), radiusM: radius, apiKey: key
                ) else { return nil }
                // Only the stop's own charger matters: a charger with no matched
                // live status reports nil and never alerts.
                let matched = ChargerStationMatching.match(charger, stations: snapshot.stations)
                return OccupancyAlertMonitor.OccupancyReport(stopChargerOccupied: matched?.isOccupied)
            }
        )
        healthEstimator = BatteryHealthEstimator(
            ratedUsableKwh: Ioniq5RoutingConstants.usableKwhForProfile(
                services.userPreferences.activeProfileId,
                customKwh: services.userPreferences.customUsableBatteryKwh
            )
        )
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true

        services.rawTelemetry
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.consume($0) }
            .store(in: &cancellables)

        // GPS follows the adapter rather than the app: with nothing connected
        // there is no trip to log, so neither the battery cost nor the permission
        // prompt is justified yet.
        services.telemetry.connectionState
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self else { return }
                self.connectionState = state
                if state == .connected {
                    self.reconnectAttempt = 0
                    self.location.start()
                    self.startLiveActivity()
                } else if state == .disconnected || state == .error {
                    self.location.stop()
                    self.finalizeActiveTrip()
                    self.driveMonitor.reset()
                    self.parkedEvaluator.reset()
                    self.parkedState = .unknown
                    self.lastFrameAt = nil
                    TelemetryLiveActivity.stop()
                }
            }
            .store(in: &cancellables)

        startSupervisor()

        // Close any trip the OS killed the process with mid-drive: the persisted row
        // has endTime == nil and would otherwise read "In progress" forever. This is
        // the relaunch backstop — finalizeStaleTripIfNeeded below only covers the
        // in-memory session from this launch.
        let tripLog = services.tripLog
        Task {
            do {
                try tripLog.finalizeOrphanedTrips()
            } catch {
                print("[ConnectedCarService] finalizeOrphanedTrips failed: \(error.localizedDescription)")
            }
        }

        // Defensive: an orphaned trip can only survive in memory across a
        // background/foreground cycle, not a relaunch, so this is usually a
        // no-op — but a re-entered start() with a stale session flagged should
        // not keep the old trip open either.
        finalizeStaleTripIfNeeded()
    }

    func stop() {
        isRunning = false
        supervisor?.cancel()
        supervisor = nil
        cancellables.removeAll()
        location.stop()
        finalizeActiveTrip()
        driveMonitor.reset()
        parkedEvaluator.reset()
        // Without this, a service torn down mid-drive leaves `.driving` latched and
        // every gated surface stays locked with nothing left running to unlock it.
        parkedState = .unknown
        isTripActive = false
    }

    // MARK: - Supervisor

    /// Wall-clock supervision of a session that has gone quiet.
    ///
    /// Everything else here is frame-driven, which is correct while the car is
    /// awake and wrong the moment it sleeps. Park at home, switch off and leave the
    /// dongle in: the bus stops answering, no frames arrive, and `DriveMonitor`'s
    /// five-minute idle end never fires because nothing advances its clock. The
    /// trip stays "in progress", and when charging starts an hour later the app is
    /// still holding a session that no longer carries anything — which is why a
    /// manual disconnect/reconnect was the only way to get the charge logged.
    ///
    /// So: tick on the clock rather than on frames, and treat a long silence on a
    /// nominally-connected link as a dead session worth rebuilding. The reconnect
    /// loop mirrors Android's `connectWithBackoff`.
    private func startSupervisor() {
        supervisor?.cancel()
        supervisor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.supervisorTick * 1_000_000_000))
                guard !Task.isCancelled else { return }
                guard let self, self.isRunning else { return }
                await self.superviseTick()
            }
        }
    }

    private func superviseTick() async {
        let now = Date()
        let quietFor = lastFrameAt.map { now.timeIntervalSince($0) } ?? .infinity

        // Fresh data means the frame path is doing its job — stay out of its way.
        // In particular the charge debounce must only ever see real frames.
        guard quietFor >= Self.framesQuiet else { return }

        tickDriveMonitor(now: now)

        guard !isReconnecting,
              services.hasSavedAdapter,
              !services.autoReconnectSuppressed,
              // CoreBluetooth is already holding an untimed connect for this
              // adapter. Reconnecting here would cancel the one mechanism that
              // survives the app being suspended.
              !services.obdManager.isRecoveringLink else { return }

        switch connectionState {
        case .connected where quietFor >= Self.sessionDead:
            // Connected but silent: tear the session down so the reconnect below
            // rebuilds it. A dead BLE link reports no drop of its own.
            await reconnect(afterTeardown: true)
        case .disconnected, .error:
            await reconnect(afterTeardown: false)
        default:
            break
        }
    }

    /// Advances the trip state machine on wall-clock time while the bus is quiet.
    ///
    /// `rawIsCharging` is deliberately false: a synthetic frame carries no evidence
    /// of current flowing, and feeding stale telemetry back in would let a regen
    /// burst from the end of the drive ripen into a "charge" long after the fact.
    /// Real charging keeps frames coming, so this path never runs during one.
    private func tickDriveMonitor(now: Date) {
        guard driveMonitor.tripActive else { return }

        let frame = DriveFrame(
            connected: connectionState == .connected,
            rawIsCharging: false,
            rawChargeType: nil,
            odometerKm: lastTelemetry.odometerKm,
            fix: location.latestFix,
            inVehicle: location.isInVehicle,
            hasLocationPermission: location.hasLocationPermission,
            hasMotionPermission: location.hasMotionPermission,
            now: now
        )
        let decision = driveMonitor.onFrame(frame)
        updateParkedState(decision: decision, frame: frame)
        handleTransition(decision.transition, telemetry: lastTelemetry)
    }

    private func reconnect(afterTeardown: Bool) async {
        isReconnecting = true
        defer { isReconnecting = false }

        if afterTeardown {
            await services.disconnect(userInitiated: false)
        }

        let delay = Self.reconnectBackoff[min(reconnectAttempt, Self.reconnectBackoff.count - 1)]
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        guard !Task.isCancelled, isRunning else { return }

        // Unlike Android there is no give-up: an iOS app with no session is not
        // burning a foreground service, and the car waking up hours later is
        // exactly the case this exists to catch.
        if await services.autoConnectLastAdapter() {
            reconnectAttempt = 0
        } else {
            reconnectAttempt += 1
        }
    }

    /// Closes an in-progress trip when the adapter drops or the pipeline is torn down.
    ///
    /// `DriveMonitor` only emits `.end` from a telemetry frame, and once the adapter
    /// is gone no further frames arrive — so its 90 s disconnect grace never gets to
    /// fire and the trip is left at its 0 km / no-end-time start defaults, showing as
    /// "in progress" forever. `endTrip` is idempotent (it no-ops without an active
    /// trip id), so racing the frame-driven path here cannot finalize twice.
    private func finalizeActiveTrip() {
        let wasActive = driveMonitor.tripActive
        let telemetry = lastTelemetry
        isTripActive = false

        let tripLog = services.tripLog
        Task {
            do {
                if wasActive {
                    try await tripLog.endTrip(telemetry: telemetry)
                    await updateCalibration()
                } else {
                    // No trip to close, but samples may still be buffered from one
                    // the frame-driven path already ended.
                    try tripLog.flushPendingSamples()
                }
            } catch {
                print("[ConnectedCarService] finalizeActiveTrip failed: \(error.localizedDescription)")
            }
        }
    }

    /// Resume hook, called from the SwiftUI scenePhase change when the app
    /// becomes active again.
    func appDidBecomeActive() {
        // Relaunch backstop for trips the OS killed mid-drive (see start()).
        let tripLog = services.tripLog
        Task {
            do {
                try tripLog.finalizeOrphanedTrips()
            } catch {
                print("[ConnectedCarService] finalizeOrphanedTrips failed: \(error.localizedDescription)")
            }
        }
        finalizeStaleTripIfNeeded()
    }

    /// Ends a trip whose frames stopped arriving long ago.
    ///
    /// `DriveMonitor`'s five-minute idle end advances on frames (or supervisor
    /// ticks), and when iOS suspends the app — car parked, bus silent, screen
    /// off — the supervisor Task freezes with everything else. Without this the
    /// trip stays "in progress" until the user manually disconnects. This is
    /// the backstop: called on resume and service start, it closes any active
    /// trip that has seen no decoded frame for `tripIdleEnd`, then resets the
    /// monitor so the next drive starts clean instead of resuming a dead
    /// session (the monitor's `.end` can only fire from a frame).
    private func finalizeStaleTripIfNeeded(now: Date = Date()) {
        guard driveMonitor.tripActive, isTripActive else { return }
        let stale = lastFrameAt.map { now.timeIntervalSince($0) > Self.tripIdleEnd } ?? true
        guard stale else { return }
        finalizeActiveTrip()
        driveMonitor.reset()
        parkedEvaluator.reset()
        parkedState = .unknown
    }

    // MARK: - Pipeline

    private func consume(_ raw: VehicleTelemetry) {
        lastFrameAt = Date()
        let frame = DriveFrame(
            connected: raw.connectionState == .connected,
            rawIsCharging: raw.isCharging,
            rawChargeType: raw.chargeType,
            odometerKm: raw.odometerKm,
            fix: location.latestFix,
            inVehicle: location.isInVehicle,
            hasLocationPermission: location.hasLocationPermission,
            hasMotionPermission: location.hasMotionPermission,
            now: Date()
        )
        let decision = driveMonitor.onFrame(frame)

        // The decoder only knows "pack current is positive", which regen also
        // satisfies. Everything downstream must see the corrected view, so the
        // charge/speed fields are overwritten before anyone else reads them.
        var telemetry = raw
        telemetry.speedKph = decision.speedKph ?? raw.speedKph
        telemetry.isCharging = decision.isCharging
        telemetry.chargeType = decision.chargeType
        lastTelemetry = telemetry

        // Published before the monitors run so the dashboard and CarPlay never show
        // the uncorrected frame — regen on the move used to read as "charging"
        // because the raw stream went to the repository directly.
        services.telemetry.update(telemetry)

        updateParkedState(decision: decision, frame: frame)
        handleTransition(decision.transition, telemetry: telemetry)
        logSample(telemetry, fix: frame.fix, inVehicle: decision.tripActive)

        chargeAlerts.onTelemetry(telemetry)
        tirePressure.onTelemetry(telemetry)
        updateHealthEstimate(telemetry)
        updateLiveActivity(telemetry)
        checkPlanProgress(telemetry, fix: frame.fix)
    }

    // MARK: - Live Activity (lock screen / Dynamic Island)

    private var lastLiveActivityAt: Date = .distantPast
    private var lastLiveActivitySoc: Float?
    private var lastLiveActivityCharging = false

    private func startLiveActivity() {
        lastLiveActivityAt = .distantPast
        let soc = lastTelemetry.socDisplay ?? lastTelemetry.socBms
        TelemetryLiveActivity.start(
            vehicleName: services.userPreferences.customVehicleName ?? "IONIQ 5",
            soc: Double(soc ?? 0),
            rangeKm: nominalRange(soc: soc),
            isCharging: lastTelemetry.isCharging
        )
    }

    /// Updates the Live Activity on a SOC or charging change, or every 30 s —
    /// not on every 1 Hz frame (ActivityKit updates are not free).
    private func updateLiveActivity(_ telemetry: VehicleTelemetry) {
        let soc = telemetry.socDisplay ?? telemetry.socBms
        guard soc != lastLiveActivitySoc || telemetry.isCharging != lastLiveActivityCharging
            || Date().timeIntervalSince(lastLiveActivityAt) > 30 else { return }
        lastLiveActivitySoc = soc
        lastLiveActivityCharging = telemetry.isCharging
        lastLiveActivityAt = Date()
        TelemetryLiveActivity.update(
            soc: Double(soc ?? 0),
            rangeKm: nominalRange(soc: soc),
            isCharging: telemetry.isCharging
        )
    }

    /// Nominal mixed-driving range from the current SOC — the same figure the
    /// dashboard shows before enough trips are logged to calibrate.
    private func nominalRange(soc: Float?) -> Double {
        guard let soc else { return 0 }
        let usable = Ioniq5RoutingConstants.usableKwhForProfile(
            services.userPreferences.activeProfileId,
            customKwh: services.userPreferences.customUsableBatteryKwh
        )
        return Double(soc) / 100.0 * usable / 18.0 * 100.0
    }

    // MARK: - Active plan

    /// Watches progress against the active plan: consumption drift and off-route
    /// (always), plus charger occupancy ahead (Pro, and only with a Places key —
    /// those calls bill the user).
    private func checkPlanProgress(_ telemetry: VehicleTelemetry, fix: Fix?) {
        guard let plan = services.activePlan.currentPlan else { return }

        let position = fix.map { LatLon(lat: $0.lat, lon: $0.lon) }
        let routePoints = services.activePlan.currentRoutePoints

        if let advice = replanMonitor.onTelemetry(
            telemetry: telemetry,
            plan: plan,
            routePoints: routePoints,
            position: position
        ) {
            services.activePlan.setReplanAdvice(advice)
            Task {
                await notifier.post(.replanAdvice, title: "Plan update", body: advice)
            }
        }

        let prefs = services.userPreferences
        guard services.isPro, prefs.chargerOccupancyAlerts,
              let key = prefs.googleMapsApiKey, !key.isEmpty else { return }

        // Only check occupancy when actively navigating — the plan may be a saved
        // trip being reviewed.
        guard (services.activePlan as? ActivePlanHolderImpl)?.currentIsNavigating ?? false else { return }

        Task { [weak self] in
            guard let self else { return }
            guard let alert = await self.occupancyMonitor.check(
                plan: plan,
                routePoints: routePoints,
                position: position,
                speedKph: telemetry.speedKph ?? 0,
                apiKey: key
            ) else { return }
            await self.handleOccupancyAlert(
                alert, plan: plan, routePoints: routePoints,
                position: position, telemetry: telemetry
            )
        }
    }

    /// Called once the driver accepts a re-route, so the next stop on the new plan
    /// can be checked immediately instead of waiting out the recheck interval.
    func onRerouteCommitted() {
        occupancyMonitor.reset()
        replanMonitor.reset()
    }

    /// Turns an occupancy alert into the most useful thing we can say, in the same
    /// three cases Android distinguishes: an alternative is reachable (offer it),
    /// range can be assessed and nothing is reachable (say so), or we cannot tell.
    private func handleOccupancyAlert(
        _ alert: OccupancyAlertMonitor.Alert,
        plan: TripPlan,
        routePoints: [LatLon],
        position: LatLon?,
        telemetry: VehicleTelemetry
    ) async {
        let liveSoc = telemetry.socDisplay ?? telemetry.socBms
        let busy = "\(alert.stopName) is full — about \(alert.etaMinutes) min ahead."

        // Needs a fix, a live SOC and a route to say anything about reachability.
        guard let position, let liveSoc, routePoints.count >= 2 else {
            await notifier.post(
                .chargerOccupancy,
                title: "Next stop is full",
                body: "\(busy) Consider an alternative stop."
            )
            return
        }

        if let reroute = await computeReroute(
            plan: plan, routePoints: routePoints, position: position,
            liveSoc: liveSoc, occupiedChargerId: alert.occupiedChargerId,
            telemetry: telemetry
        ) {
            // Park the alternative first: the notification action commits it, so it
            // has to be waiting before the alert can be tapped.
            services.activePlan.setPendingReroute(reroute.plan, points: reroute.remainingRoute)
            let altText = reroute.plan.stops.first.map {
                "Re-route to \($0.charger.name) (arrive ~\(Int($0.arrivalSoc))%)."
            } ?? "An alternative charger is reachable on your current charge."
            await notifier.post(
                .chargerOccupancy,
                title: "Next stop is full",
                body: "\(busy) \(altText)",
                categoryIdentifier: AlertNotifier.occupancyRerouteCategory
            )
        } else {
            await notifier.post(
                .chargerOccupancy,
                title: "Next stop is full",
                body: "\(busy) No charger is reachable on your current charge; "
                    + "reduce speed to extend range."
            )
        }
    }

    /// Re-solves the remaining route from here, on the current charge, excluding the
    /// stop that is full. Mirrors Android's `computeReroute`.
    private func computeReroute(
        plan: TripPlan,
        routePoints: [LatLon],
        position: LatLon,
        liveSoc: Float,
        occupiedChargerId: String,
        telemetry: VehicleTelemetry
    ) async -> Rerouted? {
        let prefs = services.userPreferences
        let nearestIdx = RouteGeo.nearestIndex(position: position, points: routePoints)
        let remaining = Array(routePoints[nearestIdx...])
        guard remaining.count >= 2 else { return nil }

        guard let candidates = try? await services.chargers.chargersAlongRoute(
            routePoints: remaining, corridorKm: 5
        ) else { return nil }

        let usable = candidates.filter { charger in
            charger.connectors.contains { prefs.connectorTypes.contains($0.type) }
        }
        guard !usable.isEmpty else { return nil }

        let packTemp = telemetry.moduleTempsC.max().map(Float.init) ?? 25
        let params = SolverParams(
            usableKwh: Double(Ioniq5Constants.usableKwhForProfile(
                prefs.activeProfileId, customKwh: prefs.customUsableBatteryKwh
            )),
            startSocPercent: liveSoc,
            reserveSocPercent: prefs.reserveSocPercent,
            arrivalReservePercent: prefs.targetArrivalSocPercent,
            packTempC: packTemp,
            priceWeight: prefs.priceWeight
        )

        return routeReplanner.reroute(
            currentPosition: position,
            liveSocPercent: liveSoc,
            plan: plan,
            routePoints: routePoints,
            candidateChargers: usable,
            occupiedChargerId: occupiedChargerId,
            paramsTemplate: params
        )
    }

    private func updateParkedState(decision: DriveDecision, frame: DriveFrame) {
        parkedState = parkedEvaluator.onFrame(
            speedKph: decision.speedKph,
            connected: frame.connected,
            charging: decision.isCharging,
            now: frame.now
        )
    }

    private func handleTransition(_ transition: TripTransition, telemetry: VehicleTelemetry) {
        switch transition {
        case .none:
            break
        case .start:
            // Defensive: `DriveMonitor` only emits `.start` from a non-active
            // state, so a trip still flagged here means an earlier one never got
            // its `.end` (normally the idle end or the resume hook closes it
            // first). Finalize it before opening the new one so two drives
            // never merge into a single log entry.
            if driveMonitor.tripActive, isTripActive {
                finalizeActiveTrip()
            }
            isTripActive = true
            do {
                try services.tripLog.startTrip(telemetry: telemetry)
            } catch {
                print("[ConnectedCarService] startTrip failed: \(error.localizedDescription)")
            }
        case .end:
            isTripActive = false
            Task {
                do {
                    try await services.tripLog.endTrip(telemetry: telemetry)
                    await updateCalibration()
                } catch {
                    print("[ConnectedCarService] endTrip failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Folds the just-finished trip's measured energy into the driver's
    /// calibration factors and persists them. Every subsequent estimate and
    /// plan is scaled by these — the "driving behaviour" that makes the model
    /// personal across sessions.
    ///
    /// Safe to run after every trip: `CalibrationUpdater` no-ops on trips too
    /// short to mean anything, and `CalibrationFactors.isApplicable` keeps the
    /// factors out of the model until enough distance has been fitted.
    private func updateCalibration() async {
        guard let trip = (try? services.tripLog.trips())?.first else { return }
        guard let endTime = trip.endTime else { return }

        let duration = endTime.timeIntervalSince(trip.startTime)
        let speedKph = duration > 0 ? Double(trip.distanceKm) / duration * 3600 : 0
        let elevation = (try? services.tripLog.netElevationGainM(tripId: trip.id)) ?? nil

        let updater = CalibrationUpdater(factors: CalibrationFactors(
            snapshot: services.userPreferences.calibration
        ))
        let updated = updater.update(
            distanceKm: Double(trip.distanceKm),
            speedKph: speedKph,
            elevationGainM: Double(elevation ?? 0),
            ambientC: trip.ambientTempAvgC ?? 20,
            actualEnergyKwh: Double(trip.energyUsedKwh)
        )

        await services.preferences.update { prefs in
            var next = prefs
            next.calibration = updated.snapshot
            return next
        }
    }

    private func logSample(_ telemetry: VehicleTelemetry, fix: Fix?, inVehicle: Bool) {
        do {
            try services.tripLog.onTelemetry(
                telemetry: telemetry,
                lat: fix?.lat,
                lon: fix?.lon,
                inVehicle: inVehicle
            )
        } catch {
            print("[ConnectedCarService] sample logging failed: \(error.localizedDescription)")
        }
    }

    /// Persists a new SOH estimate so it survives relaunch — a qualifying charge
    /// session is rare enough that recomputing from scratch each launch would mean
    /// the figure almost never appears.
    private func updateHealthEstimate(_ telemetry: VehicleTelemetry) {
        guard let soh = healthEstimator.onTelemetry(telemetry), soh != estimatedSohPercent else {
            return
        }
        estimatedSohPercent = soh
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        Task {
            await services.preferences.update { current in
                var next = current
                next.estimatedSohPercent = soh
                next.estimatedSohTimestamp = timestamp
                return next
            }
        }
    }

    // MARK: - Alerts

    private func postChargeAlert(threshold: Float, soc: Float) {
        let title = threshold >= 100 ? "Charging complete" : "Charged to \(Int(threshold))%"
        Task {
            await notifier.post(
                .chargeMilestone,
                title: title,
                body: String(format: "Battery is at %.0f%%.", soc)
            )
        }
    }

    private func postTireAlert(_ low: [(String, Int)]) {
        let detail = low.map { "\($0.0) \($0.1) kPa" }.joined(separator: ", ")
        Task {
            await notifier.post(
                .tirePressure,
                title: low.count > 1 ? "Low tyre pressure" : "Low tyre pressure: \(low[0].0)",
                body: detail
            )
        }
    }
}
