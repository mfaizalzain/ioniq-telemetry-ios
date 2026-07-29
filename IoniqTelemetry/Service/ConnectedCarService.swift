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
            availabilityNear: { [occupancy = services.occupancy] center, radius, key in
                guard let snapshot = try? await occupancy.occupancyNear(
                    center, radiusM: radius, apiKey: key
                ) else { return nil }
                return OccupancyAlertMonitor.OccupancyReport(
                    stationCount: snapshot.stations.count,
                    hasStatus: snapshot.hasStatus,
                    allOccupied: snapshot.allOccupied
                )
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
                } else if state == .disconnected || state == .error {
                    self.location.stop()
                    self.finalizeActiveTrip()
                    self.driveMonitor.reset()
                    self.parkedEvaluator.reset()
                    self.parkedState = .unknown
                    self.lastFrameAt = nil
                }
            }
            .store(in: &cancellables)

        startSupervisor()
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
        checkPlanProgress(telemetry, fix: frame.fix)
    }

    // MARK: - Active plan

    /// Watches progress against the active plan: consumption drift and off-route
    /// (always), plus charger occupancy ahead (Pro, and only with a Places key —
    /// those calls bill the user).
    private func checkPlanProgress(_ telemetry: VehicleTelemetry, fix: Fix?) {
        let plan = services.activePlan.currentPlan
        guard plan != nil else { return }

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
            await self.notifier.post(
                .chargerOccupancy,
                title: "\(alert.stopName) looks full",
                body: "All \(alert.statusedStations) chargers with live status are in use, about \(alert.etaMinutes) min ahead."
            )
        }
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
                } catch {
                    print("[ConnectedCarService] endTrip failed: \(error.localizedDescription)")
                }
            }
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
