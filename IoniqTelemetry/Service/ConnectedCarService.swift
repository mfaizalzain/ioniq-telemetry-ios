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

        services.telemetry.state
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
                if state == .connected {
                    self.location.start()
                } else if state == .disconnected || state == .error {
                    self.location.stop()
                    self.driveMonitor.reset()
                    self.parkedEvaluator.reset()
                    self.parkedState = .unknown
                }
            }
            .store(in: &cancellables)
    }

    func stop() {
        isRunning = false
        cancellables.removeAll()
        location.stop()
        driveMonitor.reset()
        parkedEvaluator.reset()
        // Without this, a service torn down mid-drive leaves `.driving` latched and
        // every gated surface stays locked with nothing left running to unlock it.
        parkedState = .unknown
        isTripActive = false
    }

    // MARK: - Pipeline

    private func consume(_ raw: VehicleTelemetry) {
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

        updateParkedState(decision: decision, frame: frame)
        handleTransition(decision.transition, telemetry: telemetry)
        logSample(telemetry, fix: frame.fix, inVehicle: decision.tripActive)

        if decision.transition == .start {
            print("[ConnectedCar] trip started — fix=\(frame.fix != nil ? "YES" : "NO") odo=\(frame.odometerKm ?? -1)")
        } else if decision.transition == .end {
            print("[ConnectedCar] trip ended")
        }

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
