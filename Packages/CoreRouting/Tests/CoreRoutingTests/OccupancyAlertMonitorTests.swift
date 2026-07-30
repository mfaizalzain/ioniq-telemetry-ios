import CoreDomain
import Foundation
import Testing
@testable import CoreRouting

/// The availability closure is `@Sendable`, so a plain captured counter cannot be
/// mutated from it.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func record() { lock.withLock { value += 1 } }
}

/// Mirrors Android's `OccupancyAlertMonitorTest`, which had no counterpart here —
/// CoreRouting had no test target at all, so the gating, throttling and
/// alert-once behaviour of the occupancy feature was unverified on iOS.
@Suite("OccupancyAlertMonitor")
@MainActor
struct OccupancyAlertMonitorTests {

    // 11 points along a meridian; index i sits at lat i*0.1 over a 100 km route, so
    // a position on point[i] is i/10 of the way along — 20 km at point[2].
    private var routePoints: [LatLon] { (0...10).map { LatLon(lat: Double($0) * 0.1, lon: 0) } }
    private var positionAt20km: LatLon { LatLon(lat: 0.2, lon: 0) }

    private func charger(_ id: String) -> Charger {
        Charger(id: id, name: "Stop \(id)", lat: 0.25, lon: 0, maxPowerKw: 150, isOperational: true)
    }

    private func planWithStop(atKm km: Float, chargerId: String = "c1") -> TripPlan {
        TripPlan(
            origin: LatLon(lat: 0, lon: 0),
            destination: LatLon(lat: 1, lon: 0),
            stops: [ChargeStop(
                charger: charger(chargerId), arrivalSoc: 15, departureSoc: 80,
                chargeMinutes: 25, energyAddedKwh: 40, distanceFromOriginKm: km
            )],
            totalDistanceKm: 100,
            totalDriveMinutes: 90,
            totalChargeMinutes: 25,
            arrivalSoc: 20,
            generatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    /// A report as the repository would build it: `stationCount` counts only
    /// stations that reported live status.
    private func report(stations: Int, allOccupied: Bool) -> OccupancyAlertMonitor.OccupancyReport {
        OccupancyAlertMonitor.OccupancyReport(
            stationCount: stations, hasStatus: stations > 0, allOccupied: allOccupied
        )
    }

    private func monitor(
        returning report: OccupancyAlertMonitor.OccupancyReport?
    ) -> OccupancyAlertMonitor {
        OccupancyAlertMonitor(availabilityNear: { _, _, _ in report })
    }

    // MARK: - Alerting

    @Test("alerts when the next stop is imminent and every statused charger is busy")
    func alertsWhenImminentAndFull() async {
        let m = monitor(returning: report(stations: 2, allOccupied: true))
        // Stop at 25 km with ~20 km travelled → a few km out at 60 kph.
        let alert = await m.check(
            plan: planWithStop(atKm: 25), routePoints: routePoints,
            position: positionAt20km, speedKph: 60, apiKey: "k"
        )
        #expect(alert?.stopName == "Stop c1")
        #expect(alert?.statusedStations == 2)
        #expect((alert?.etaMinutes ?? 0) >= 1)
    }

    @Test("no alert when at least one charger is free")
    func noAlertWhenOneFree() async {
        let m = monitor(returning: report(stations: 2, allOccupied: false))
        let alert = await m.check(
            plan: planWithStop(atKm: 25), routePoints: routePoints,
            position: positionAt20km, speedKph: 60, apiKey: "k"
        )
        #expect(alert == nil)
    }

    /// "No data" must never be read as "occupied", or the feature invents alerts.
    @Test("no alert when nothing reports live status")
    func noAlertWithoutStatus() async {
        let m = monitor(returning: report(stations: 0, allOccupied: false))
        let alert = await m.check(
            plan: planWithStop(atKm: 25), routePoints: routePoints,
            position: positionAt20km, speedKph: 60, apiKey: "k"
        )
        #expect(alert == nil)
    }

    /// A failed lookup is also "no information", not "occupied".
    @Test("no alert when the availability lookup fails")
    func noAlertOnLookupFailure() async {
        let m = monitor(returning: nil)
        let alert = await m.check(
            plan: planWithStop(atKm: 25), routePoints: routePoints,
            position: positionAt20km, speedKph: 60, apiKey: "k"
        )
        #expect(alert == nil)
    }

    // MARK: - Gating

    @Test("no alert while the stop is beyond the ETA threshold")
    func noAlertBeyondThreshold() async {
        let m = monitor(returning: report(stations: 2, allOccupied: true))
        // 90 km out at 60 kph is 90 minutes — far past the 10-minute window.
        let alert = await m.check(
            plan: planWithStop(atKm: 95), routePoints: routePoints,
            position: positionAt20km, speedKph: 60, apiKey: "k"
        )
        #expect(alert == nil)
    }

    @Test("no alert without an API key — these calls bill the user")
    func noAlertWithoutKey() async {
        for key in [nil, ""] as [String?] {
            let m = monitor(returning: report(stations: 2, allOccupied: true))
            let alert = await m.check(
                plan: planWithStop(atKm: 25), routePoints: routePoints,
                position: positionAt20km, speedKph: 60, apiKey: key
            )
            #expect(alert == nil)
        }
    }

    @Test("no alert when stationary — a standing car has no meaningful ETA")
    func noAlertWhenStationary() async {
        let m = monitor(returning: report(stations: 2, allOccupied: true))
        let alert = await m.check(
            plan: planWithStop(atKm: 25), routePoints: routePoints,
            position: positionAt20km, speedKph: 0, apiKey: "k"
        )
        #expect(alert == nil)
    }

    @Test("no alert without a plan, a position, or a usable route")
    func noAlertWithoutInputs() async {
        let m = monitor(returning: report(stations: 2, allOccupied: true))
        #expect(await m.check(plan: nil, routePoints: routePoints, position: positionAt20km, speedKph: 60, apiKey: "k") == nil)
        #expect(await m.check(plan: planWithStop(atKm: 25), routePoints: routePoints, position: nil, speedKph: 60, apiKey: "k") == nil)
        #expect(await m.check(plan: planWithStop(atKm: 25), routePoints: [], position: positionAt20km, speedKph: 60, apiKey: "k") == nil)
    }

    @Test("stops already behind the driver are not considered")
    func passedStopsIgnored() async {
        let m = monitor(returning: report(stations: 2, allOccupied: true))
        // Stop at 5 km, driver at ~20 km — already passed.
        let alert = await m.check(
            plan: planWithStop(atKm: 5), routePoints: routePoints,
            position: positionAt20km, speedKph: 60, apiKey: "k"
        )
        #expect(alert == nil)
    }

    // MARK: - Throttling and de-duplication

    @Test("alerts at most once per stop")
    func alertsOncePerStop() async {
        let m = monitor(returning: report(stations: 2, allOccupied: true))
        let plan = planWithStop(atKm: 25)
        let first = await m.check(
            plan: plan, routePoints: routePoints, position: positionAt20km,
            speedKph: 60, apiKey: "k", now: Date(timeIntervalSince1970: 0)
        )
        #expect(first != nil)

        // Well past the recheck interval, so only the per-stop guard can suppress it.
        let second = await m.check(
            plan: plan, routePoints: routePoints, position: positionAt20km,
            speedKph: 60, apiKey: "k", now: Date(timeIntervalSince1970: 3600)
        )
        #expect(second == nil)
    }

    /// The throttle is what stops the un-throttled telemetry stream from turning
    /// into a billed Places call per frame.
    @Test("a second check inside the recheck interval does not poll again")
    func throttledWithinInterval() async {
        let calls = CallCounter()
        let m = OccupancyAlertMonitor(availabilityNear: { _, _, _ in
            calls.record()
            return OccupancyAlertMonitor.OccupancyReport(
                stationCount: 2, hasStatus: true, allOccupied: false
            )
        })
        let plan = planWithStop(atKm: 25)
        for offset in [0.0, 1.0, 60.0, 120.0] {
            _ = await m.check(
                plan: plan, routePoints: routePoints, position: positionAt20km,
                speedKph: 60, apiKey: "k", now: Date(timeIntervalSince1970: offset)
            )
        }
        #expect(calls.count == 1, "four frames in one 4-minute window billed \(calls.count) calls")
    }

    /// `ConnectedCarService` spawns an unstructured Task per telemetry frame with no
    /// in-flight guard (Android has one), so the throttle is the only thing standing
    /// between an un-throttled telemetry stream and a billed Places call per frame.
    /// It holds because `lastCheck` is set before the lookup suspends.
    @Test("concurrent checks in the same instant bill one lookup, not many")
    func concurrentChecksBillOnce() async {
        let lookups = CallCounter()
        let m = OccupancyAlertMonitor(availabilityNear: { _, _, _ in
            lookups.record()
            // Suspend, so any task that slipped past the throttle would overlap here.
            await Task.yield()
            return OccupancyAlertMonitor.OccupancyReport(
                stationCount: 2, hasStatus: true, allOccupied: false
            )
        })
        let plan = planWithStop(atKm: 25)
        let now = Date(timeIntervalSince1970: 0)
        let points = routePoints
        let position = positionAt20km

        func frame() async -> OccupancyAlertMonitor.Alert? {
            await m.check(
                plan: plan, routePoints: points, position: position,
                speedKph: 60, apiKey: "k", now: now
            )
        }

        async let a = frame()
        async let b = frame()
        async let c = frame()
        async let d = frame()
        _ = await (a, b, c, d)

        #expect(lookups.count == 1, "four concurrent frames billed \(lookups.count) Places calls")
    }

    @Test("a new plan re-arms the alert for the same charger")
    func newPlanReArms() async {
        let m = monitor(returning: report(stations: 2, allOccupied: true))
        let first = await m.check(
            plan: planWithStop(atKm: 25), routePoints: routePoints, position: positionAt20km,
            speedKph: 60, apiKey: "k", now: Date(timeIntervalSince1970: 0)
        )
        #expect(first != nil)

        // Same charger id, but a re-planned trip — the driver should hear about it again.
        var replanned = planWithStop(atKm: 25)
        replanned.generatedAt = Date(timeIntervalSince1970: 999)
        let second = await m.check(
            plan: replanned, routePoints: routePoints, position: positionAt20km,
            speedKph: 60, apiKey: "k", now: Date(timeIntervalSince1970: 3600)
        )
        #expect(second != nil)
    }

    @Test("reset clears both the per-stop guard and the throttle")
    func resetClearsState() async {
        let m = monitor(returning: report(stations: 2, allOccupied: true))
        let plan = planWithStop(atKm: 25)
        _ = await m.check(
            plan: plan, routePoints: routePoints, position: positionAt20km,
            speedKph: 60, apiKey: "k", now: Date(timeIntervalSince1970: 0)
        )
        m.reset()
        let afterReset = await m.check(
            plan: plan, routePoints: routePoints, position: positionAt20km,
            speedKph: 60, apiKey: "k", now: Date(timeIntervalSince1970: 1)
        )
        #expect(afterReset != nil)
    }
}

/// `projectOntoRoute` decides how far along the route the driver is, which sets the
/// ETA every alert threshold is measured against.
@Suite("Route projection")
struct RouteProjectionTests {

    /// 11 points, indices 0...10. Point[i] is i/10 of the way along, not i/11:
    /// the fraction is over the number of *segments*, not the number of points.
    /// Android's monitor divides by `points.size - 1`; this pinned the iOS
    /// behaviour to match.
    @Test("a point i of n-1 segments projects to i/(n-1) of the total distance")
    func projectsOverSegments() {
        let points = (0...10).map { LatLon(lat: Double($0) * 0.1, lon: 0) }

        let (start, _) = RouteGeo.projectOntoRoute(points: points, lat: 0, lon: 0, totalKm: 100)
        #expect(abs(start - 0) < 0.01)

        let (middle, _) = RouteGeo.projectOntoRoute(points: points, lat: 0.5, lon: 0, totalKm: 100)
        #expect(abs(middle - 50) < 0.01, "midpoint should be 50 km, got \(middle)")

        let (end, _) = RouteGeo.projectOntoRoute(points: points, lat: 1.0, lon: 0, totalKm: 100)
        #expect(abs(end - 100) < 0.01, "the last point is the whole route, got \(end)")
    }

    @Test("a two-point route projects its end to the full distance")
    func twoPointRoute() {
        let points = [LatLon(lat: 0, lon: 0), LatLon(lat: 1, lon: 0)]
        let (end, _) = RouteGeo.projectOntoRoute(points: points, lat: 1, lon: 0, totalKm: 100)
        #expect(abs(end - 100) < 0.01, "expected 100 km, got \(end)")
    }

    @Test("an empty route projects to zero rather than dividing by zero")
    func emptyRoute() {
        let (along, distance) = RouteGeo.projectOntoRoute(points: [], lat: 1, lon: 1, totalKm: 100)
        #expect(along == 0)
        #expect(distance == 0)
    }
}
