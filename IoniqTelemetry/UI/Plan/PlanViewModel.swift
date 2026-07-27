import Combine
import CoreDomain
import CoreLocation
import CoreRouting
import Foundation
import MapKit

/// Trip planning: place search → base route → chargers along the corridor →
/// `TripSolver` for the charge stops.
///
/// The base route comes from MapKit rather than the BYOK routing providers. It
/// needs no key, so planning works out of the box; the ORS/Google keys in
/// Settings remain for elevation-aware routing, which MapKit does not expose.
@Observable
@MainActor
final class PlanViewModel {

    // MARK: - Input

    var originQuery = ""
    var destinationQuery = ""
    var departureSoc: Float = 80
    var arrivalReserve: Float = 20

    // MARK: - Output

    private(set) var originPlace: Place?
    private(set) var destinationPlace: Place?
    private(set) var suggestions: [Place] = []
    private(set) var activeField: Field?
    private(set) var plan: TripPlan?
    private(set) var nearbyChargers: [Charger] = []
    private(set) var isPlanning = false
    private(set) var statusMessage: String?
    private(set) var errorMessage: String?

    enum Field { case origin, destination }

    struct Place: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let subtitle: String
        let location: LatLon
    }

    private let services: AppServices
    private let solver = TripSolver()
    private let locationProvider = LocationProvider()
    private var telemetry = VehicleTelemetry()
    private var preferences = UserPreferences()
    private var searchTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(services: AppServices) {
        self.services = services

        services.telemetry.state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sample in
                guard let self else { return }
                self.telemetry = sample
                // Seed departure SOC from the car until the user overrides it.
                if !self.hasEditedSoc, let soc = sample.socDisplay ?? sample.socBms {
                    self.departureSoc = soc
                }
            }
            .store(in: &cancellables)

        services.preferences.preferences
            .receive(on: DispatchQueue.main)
            .sink { [weak self] prefs in
                guard let self else { return }
                self.preferences = prefs
                if !self.hasEditedReserve {
                    self.arrivalReserve = prefs.targetArrivalSocPercent
                }
            }
            .store(in: &cancellables)
    }

    private var hasEditedSoc = false
    private var hasEditedReserve = false

    func socEdited() { hasEditedSoc = true }
    func reserveEdited() { hasEditedReserve = true }

    var canPlan: Bool { originPlace != nil && destinationPlace != nil && !isPlanning }

    // MARK: - Place search

    /// Debounced so typing doesn't fire a search per keystroke.
    func search(_ query: String, field: Field) {
        activeField = field
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else {
            suggestions = []
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.runSearch(trimmed)
        }
    }

    private func runSearch(_ query: String) async {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let center = await locationProvider.currentLocation() {
            request.region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: center.lat, longitude: center.lon),
                latitudinalMeters: 200_000,
                longitudinalMeters: 200_000
            )
        }
        do {
            let response = try await MKLocalSearch(request: request).start()
            suggestions = response.mapItems.prefix(8).map { item in
                Place(
                    name: item.name ?? query,
                    subtitle: Self.subtitle(for: item.placemark),
                    location: LatLon(
                        lat: item.placemark.coordinate.latitude,
                        lon: item.placemark.coordinate.longitude
                    )
                )
            }
        } catch {
            // A failed lookup shouldn't nag: the user is still typing.
            suggestions = []
        }
    }

    func select(_ place: Place) {
        switch activeField {
        case .origin:
            originPlace = place
            originQuery = place.name
        case .destination, nil:
            destinationPlace = place
            destinationQuery = place.name
        }
        suggestions = []
        activeField = nil
    }

    func useCurrentLocation() async {
        guard let location = await locationProvider.currentLocation() else {
            errorMessage = "Location unavailable. Check permissions in Settings."
            return
        }
        originPlace = Place(name: "Current Location", subtitle: "", location: location)
        originQuery = "Current Location"
    }

    /// Drops the active plan, so the replan and occupancy monitors stop watching.
    func clearPlan() {
        plan = nil
        services.activePlan.clearPlan()
    }

    func swapEndpoints() {
        swap(&originPlace, &destinationPlace)
        swap(&originQuery, &destinationQuery)
    }

    // MARK: - Planning

    func plan() async {
        guard let origin = originPlace, let destination = destinationPlace else { return }
        isPlanning = true
        errorMessage = nil
        plan = nil
        defer { isPlanning = false }

        do {
            statusMessage = "Finding route…"
            let route = try await route(from: origin.location, to: destination.location)

            statusMessage = "Looking for chargers…"
            let chargers = try await services.chargers.chargersAlongRoute(
                routePoints: route.sampledPoints,
                corridorKm: 5
            )
            guard !chargers.isEmpty else {
                errorMessage = "No chargers found along this route."
                statusMessage = nil
                return
            }

            statusMessage = "Planning stops…"
            let routeChargers = Self.project(chargers: chargers, onto: route)
            let solved = solver.solve(
                origin: origin.location,
                destination: destination.location,
                totalRouteKm: route.distanceKm,
                chargers: routeChargers,
                params: solverParams
            )

            if let solved {
                plan = solved
                // Publish so the drive service can watch progress against it and
                // CarPlay can show the same itinerary.
                services.activePlan.setPlan(solved)
                services.activePlan.setRoute(route.sampledPoints)
                statusMessage = nil
            } else {
                errorMessage = "Couldn't find a workable charging plan. Try a higher departure charge or a lower arrival reserve."
                statusMessage = nil
            }
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
        }
    }

    private var solverParams: SolverParams {
        let packTemp = telemetry.moduleTempsC.isEmpty
            ? 25
            : Float(telemetry.moduleTempsC.reduce(0, +) / telemetry.moduleTempsC.count)
        return SolverParams(
            usableKwh: Ioniq5RoutingConstants.usableKwhForProfile(
                preferences.activeProfileId,
                customKwh: preferences.customUsableBatteryKwh
            ),
            startSocPercent: departureSoc,
            reserveSocPercent: preferences.reserveSocPercent,
            arrivalReservePercent: arrivalReserve,
            packTempC: packTemp,
            priceWeight: preferences.priceWeight,
            ambientC: Float(telemetry.ambientTempC ?? 20)
        )
    }

    // MARK: - Nearby chargers

    /// Only runs once location is already authorized. Opening the tab must not
    /// trigger the permission prompt — that belongs to an explicit user action.
    func loadNearbyChargers() async {
        guard locationProvider.isAuthorized else { return }
        guard let center = await locationProvider.currentLocation() else { return }
        nearbyChargers = (try? await services.chargers.chargersNear(center: center, radiusKm: 25)) ?? []
    }

    // MARK: - Routing

    private struct Route {
        let distanceKm: Float
        let durationMinutes: Int
        let sampledPoints: [LatLon]
    }

    private func route(from origin: LatLon, to destination: LatLon) async throws -> Route {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: origin.lat, longitude: origin.lon)
        ))
        request.destination = MKMapItem(placemark: MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: destination.lat, longitude: destination.lon)
        ))
        request.transportType = .automobile

        let response = try await MKDirections(request: request).calculate()
        guard let route = response.routes.first else {
            throw PlanError.noRoute
        }

        return Route(
            distanceKm: Float(route.distance / 1000),
            durationMinutes: Int(route.expectedTravelTime / 60),
            sampledPoints: Self.sample(polyline: route.polyline)
        )
    }

    /// Thins the polyline to roughly one point per kilometre — enough shape for a
    /// corridor query without shipping thousands of coordinates.
    private static func sample(polyline: MKPolyline) -> [LatLon] {
        var coordinates = [CLLocationCoordinate2D](
            repeating: kCLLocationCoordinate2DInvalid,
            count: polyline.pointCount
        )
        polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: polyline.pointCount))

        var result: [LatLon] = []
        var lastKept: CLLocation?
        for coordinate in coordinates {
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            if let lastKept, lastKept.distance(from: location) < 1000 { continue }
            lastKept = location
            result.append(LatLon(lat: coordinate.latitude, lon: coordinate.longitude))
        }
        return result
    }

    /// Places each charger along the route by nearest sampled point, and measures
    /// the detour as the straight-line hop off the corridor.
    private static func project(chargers: [Charger], onto route: Route) -> [RouteCharger] {
        let points = route.sampledPoints
        guard !points.isEmpty else { return [] }
        let kmPerPoint = points.count > 1 ? route.distanceKm / Float(points.count - 1) : 0

        return chargers.compactMap { charger in
            var bestIndex = 0
            var bestDistance = Double.greatestFiniteMagnitude
            for (index, point) in points.enumerated() {
                let distance = haversineKm(point, LatLon(lat: charger.lat, lon: charger.lon))
                if distance < bestDistance {
                    bestDistance = distance
                    bestIndex = index
                }
            }
            return RouteCharger(
                charger: charger,
                distanceAlongRouteKm: Float(bestIndex) * kmPerPoint,
                detourKm: Float(bestDistance)
            )
        }
        .sorted { $0.distanceAlongRouteKm < $1.distanceAlongRouteKm }
    }

    /// Street + locality when available, so "Shell" rows are distinguishable.
    private static func subtitle(for placemark: MKPlacemark) -> String {
        [placemark.thoroughfare, placemark.locality, placemark.administrativeArea]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    private static func haversineKm(_ a: LatLon, _ b: LatLon) -> Double {
        let earthRadiusKm = 6371.0
        let dLat = (b.lat - a.lat) * .pi / 180
        let dLon = (b.lon - a.lon) * .pi / 180
        let lat1 = a.lat * .pi / 180
        let lat2 = b.lat * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + sin(dLon / 2) * sin(dLon / 2) * cos(lat1) * cos(lat2)
        return 2 * earthRadiusKm * asin(min(1, sqrt(h)))
    }

    enum PlanError: LocalizedError {
        case noRoute
        var errorDescription: String? {
            switch self {
            case .noRoute: return "No driving route between those places."
            }
        }
    }
}

// MARK: - Location

/// One-shot location lookup for planning. Trip-tracking location belongs to the
/// drive-monitor service, which needs a long-running background session.
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuations: [CheckedContinuation<LatLon?, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// True once the user has granted access; false while undetermined or denied.
    var isAuthorized: Bool {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: return true
        default: return false
        }
    }

    func currentLocation() async -> LatLon? {
        if let location = manager.location {
            return LatLon(lat: location.coordinate.latitude, lon: location.coordinate.longitude)
        }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            return nil
        default:
            break
        }
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
            manager.requestLocation()
        }
    }

    private func resume(with location: LatLon?) {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume(returning: location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let value = locations.last.map {
            LatLon(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude)
        }
        Task { @MainActor in self.resume(with: value) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.resume(with: nil) }
    }
}
