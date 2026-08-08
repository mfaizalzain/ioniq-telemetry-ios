import CoreDomain
import Foundation

/// While driving an active plan, warns when the next charge stop is imminent and
/// the stop's own charger reports occupied — so the driver can pick an
/// alternative before arriving at a full station.
///
/// The alert never infers a charger's status from other stations in the area: a
/// charger with no matched live status, or with a free connector, never alerts.
/// Availability is injected rather than depended on directly, which keeps the
/// timing and gating logic testable without a network.
///
/// Calls are Pro- and key-gated by the caller, throttled to `recheckInterval`, and
/// fired at most once per stop.
///
/// Ported from Android OccupancyAlertMonitor.kt.
///
/// Main-actor isolated: its throttling state is mutable and it is driven from the
/// single drive-pipeline consumer. The network lookup still suspends off-actor.
@MainActor
public final class OccupancyAlertMonitor {

    public struct Alert: Sendable, Equatable {
        public let stopName: String
        public let occupiedChargerId: String
        public let etaMinutes: Int
    }

    /// Live occupancy of the stop's own charger. Returns nil on error, which is
    /// treated as "no information" and never as "occupied".
    public typealias AvailabilityLookup =
        @Sendable (Charger, Double, String) async -> OccupancyReport?

    /// Minimal shape the monitor needs, so CoreRouting doesn't depend on CoreData.
    /// `stopChargerOccupied` is nil when the charger has no matched live status —
    /// that must never be read as "full".
    public struct OccupancyReport: Sendable, Equatable {
        public let stopChargerOccupied: Bool?

        public init(stopChargerOccupied: Bool?) {
            self.stopChargerOccupied = stopChargerOccupied
        }
    }

    private let availabilityNear: AvailabilityLookup
    private let etaThresholdMinutes: Double
    private let searchRadiusM: Double
    private let minSpeedKph: Float
    private let recheckInterval: TimeInterval

    private var alertedStopKey: String?
    private var lastCheck: Date?

    /// - Parameter recheckInterval: the main cost lever. Within the approach window
    ///   a still-available stop is re-polled at this cadence until it either fills
    ///   up (alert) or is passed — at 4 minutes that's two or three Places calls.
    public init(
        availabilityNear: @escaping AvailabilityLookup,
        etaThresholdMinutes: Double = 10,
        searchRadiusM: Double = 800,
        minSpeedKph: Float = 5,
        recheckInterval: TimeInterval = 4 * 60
    ) {
        self.availabilityNear = availabilityNear
        self.etaThresholdMinutes = etaThresholdMinutes
        self.searchRadiusM = searchRadiusM
        self.minSpeedKph = minSpeedKph
        self.recheckInterval = recheckInterval
    }

    /// Returns an alert to surface once, or nil if there's nothing to report yet.
    public func check(
        plan: TripPlan?,
        routePoints: [LatLon],
        position: LatLon?,
        speedKph: Float,
        apiKey: String?,
        now: Date = Date()
    ) async -> Alert? {
        guard let plan, let apiKey, !apiKey.isEmpty else { return nil }
        guard let position, routePoints.count >= 2 else { return nil }
        guard speedKph >= minSpeedKph else { return nil }  // need motion for an ETA

        let (alongKm, _) = RouteGeo.projectOntoRoute(
            points: routePoints, lat: position.lat, lon: position.lon,
            totalKm: plan.totalDistanceKm
        )
        guard let nextStop = plan.stops.first(where: { $0.distanceFromOriginKm > alongKm + 0.1 }) else {
            return nil
        }

        let stopKey = "\(plan.generatedAt.timeIntervalSince1970):\(nextStop.charger.id)"
        guard stopKey != alertedStopKey else { return nil }  // already warned

        let distanceKm = nextStop.distanceFromOriginKm - alongKm
        let etaMinutes = Double(distanceKm / speedKph) * 60
        guard etaMinutes <= etaThresholdMinutes else { return nil }

        if let lastCheck, now.timeIntervalSince(lastCheck) < recheckInterval { return nil }
        lastCheck = now

        guard let report = await availabilityNear(nextStop.charger, searchRadiusM, apiKey) else { return nil }
        // Only a confirmed "occupied" for the stop's own charger alerts — a nil
        // status or a free connector never does.
        guard report.stopChargerOccupied == true else { return nil }

        alertedStopKey = stopKey
        return Alert(
            stopName: nextStop.charger.name,
            occupiedChargerId: nextStop.charger.id,
            etaMinutes: max(Int(etaMinutes), 1)
        )
    }

    public func reset() {
        alertedStopKey = nil
        lastCheck = nil
    }
}
