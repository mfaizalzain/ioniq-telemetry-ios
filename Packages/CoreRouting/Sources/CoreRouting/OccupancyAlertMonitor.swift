import CoreDomain
import Foundation

/// While driving an active plan, warns when the next charge stop is imminent and
/// every nearby charger reporting live availability is occupied — so the driver can
/// pick an alternative before arriving at a full station.
///
/// Availability is injected rather than depended on directly, which keeps the
/// timing and gating logic testable without a network. Stations with no live status
/// are ignored: "no data" is not "available".
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
        public let statusedStations: Int
        public let etaMinutes: Int
    }

    /// Live occupancy near a point. Returns nil on error, which is treated as "no
    /// information" and never as "occupied".
    public typealias AvailabilityLookup =
        @Sendable (LatLon, Double, String) async -> OccupancyReport?

    /// Minimal shape the monitor needs, so CoreRouting doesn't depend on CoreData.
    public struct OccupancyReport: Sendable, Equatable {
        public let stationCount: Int
        public let hasStatus: Bool
        public let allOccupied: Bool

        public init(stationCount: Int, hasStatus: Bool, allOccupied: Bool) {
            self.stationCount = stationCount
            self.hasStatus = hasStatus
            self.allOccupied = allOccupied
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

        guard let report = await availabilityNear(
            LatLon(lat: nextStop.charger.lat, lon: nextStop.charger.lon),
            searchRadiusM,
            apiKey
        ) else { return nil }

        guard report.hasStatus, report.allOccupied else { return nil }

        alertedStopKey = stopKey
        return Alert(
            stopName: nextStop.charger.name,
            occupiedChargerId: nextStop.charger.id,
            statusedStations: report.stationCount,
            etaMinutes: max(Int(etaMinutes), 1)
        )
    }

    public func reset() {
        alertedStopKey = nil
        lastCheck = nil
    }
}
