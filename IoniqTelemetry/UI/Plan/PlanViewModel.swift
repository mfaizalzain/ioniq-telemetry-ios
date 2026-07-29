import Combine
import CoreData
import CoreDomain
import CoreLocation
import CoreRouting
import Foundation

/// Trip planning: place search → routed path → chargers along the corridor →
/// `TripSolver` for the charge stops.
///
/// Routing and geocoding go through the user's configured provider
/// (OpenRouteService or Google), matching the Android build — OpenRouteService
/// returns ascent/descent, which is what lets `ConsumptionModel` do real grade
/// physics instead of assuming flat ground.
@Observable
@MainActor
final class PlanViewModel {

    // MARK: - Endpoints

    /// One origin/destination/stopover slot: what the user typed, what they picked,
    /// and the suggestions currently offered for it.
    struct Endpoint: Identifiable {
        let id = UUID()
        var query: String = ""
        var selected: PlaceResult?
        var suggestions: [PlaceResult] = []
        var isSearching = false
    }

    struct ChargerAvailability: Equatable {
        let available: Int
        let total: Int

        var isFull: Bool { available == 0 }
    }

    enum Slot: Equatable {
        case origin
        case destination
        case waypoint(Int)
    }

    var origin = Endpoint()
    var destination = Endpoint()
    /// Stopovers, routed through in order between origin and destination.
    private(set) var waypoints: [Endpoint] = []
    private(set) var activeSlot: Slot?

    // MARK: - Parameters

    private(set) var departureSoc: Float = 80
    var arrivalReserve: Float = 20
    /// How far off the line a charger may sit and still be considered.
    private(set) var corridorRadiusKm: Float = 5

    /// True while the departure SOC tracks the car instead of the slider.
    private(set) var usesLiveSoc = true

    // MARK: - Output

    private(set) var plan: TripPlan?
    private(set) var routePoints: [LatLon] = []
    private(set) var hasElevationData = false
    private(set) var nearbyChargers: [Charger] = []
    /// Live connector availability by charger id, for the chargers Places could be
    /// matched to. Absent means "no live status", never "free".
    private(set) var chargerAvailability: [String: ChargerAvailability] = [:]
    private(set) var savedTrips: [SavedTrip] = []
    private(set) var favoritePlaces: [SavedPlaceEntity] = []
    /// Chargers the driver rejected; excluded from the next solve.
    private(set) var excludedChargerIds: Set<String> = []
    private(set) var isPlanning = false
    private(set) var statusMessage: String?
    private(set) var errorMessage: String?
    private(set) var routingNotice: String?

    /// The charger refresh failed and these rows came from the local cache. The
    /// repository has always published this; nothing displayed it, so a driver
    /// planning against week-old data had no way to know.
    private(set) var chargersAreCached = false

    /// Said up front rather than after a request times out — planning a route is
    /// the one thing on this screen that cannot work offline.
    private(set) var isOffline = false
    private(set) var isPro = false

    // MARK: - AI Natural Language Planning

    /// Natural language input text for the AI planning card.
    var nlInput: String = ""
    /// True while the AI is interpreting the NL request.
    private(set) var nlBusy = false
    /// The AI's interpreted plan text, shown in an expandable banner.
    private(set) var nlInterpretation: String?
    /// Error message from AI planning.
    private(set) var nlError: String?

    /// True when the selected AI provider has a usable key.
    var hasKey: Bool { preferences.aiKey.map { !$0.isEmpty } ?? false }

    /// The API key for the selected AI provider.
    var aiKey: String? { preferences.aiKey }

    /// The selected AI provider (Gemini or DeepSeek).
    var aiProvider: AiProvider { preferences.aiProvider }

    /// Master toggle for all AI-powered features.
    var aiFeaturesEnabled: Bool { preferences.aiFeaturesEnabled }

    /// Updates the NL input and clears any previous result/error.
    func setNlInput(_ text: String) {
        nlInput = text
        nlError = nil
        nlInterpretation = nil
    }

    /// Sends the natural language input to the selected AI provider and
    /// stores the interpretation. Uses the same `AiService` pattern as
    /// `AiAssistantChatView`.
    func planFromNaturalLanguage() async {
        let trimmed = nlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let apiKey = preferences.aiKey, !apiKey.isEmpty else {
            nlError = "AI API key is not configured. Add one in Settings."
            return
        }

        nlBusy = true
        nlError = nil
        nlInterpretation = nil
        defer { nlBusy = false }

        let location = await locationProvider.currentLocation()
        let locationContext: String
        if let loc = location {
            locationContext = String(
                format: "Current location: lat %.4f, lon %.4f",
                loc.lat, loc.lon
            )
        } else {
            locationContext = "Current location: unknown"
        }

        let prompt = """
        You are an EV trip planning assistant. The user wants to plan a route using \
        natural language. Convert their request into a structured trip plan.

        \(locationContext)

        User request: \(trimmed)

        If the user asks about nearby charging, respond with "NEARBY_CHARGERS" as the intent.
        If they specify a destination, extract the destination name and any waypoints.
        Keep your response concise (2-3 sentences) and focused on what the user asked.
        """

        let aiService = AiService()
        do {
            let response = try await aiService.askCopilotWithContext(
                query: prompt,
                telemetryContext: locationContext,
                apiKey: apiKey,
                aiProvider: preferences.aiProvider
            )
            nlInterpretation = response
        } catch {
            nlError = error.localizedDescription
        }
    }

    private let services: AppServices
    private let solver = TripSolver()
    private let locationProvider = LocationProvider()
    private var telemetry = VehicleTelemetry()
    private var preferences = UserPreferences()
    private var searchTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    /// Cached so a re-route doesn't re-request the route and burn another API call.
    private var lastRoute: BaseRoute?
    private(set) var lastRouteChargers: [RouteCharger] = []

    init(services: AppServices) {
        self.services = services

        services.telemetry.state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sample in
                guard let self else { return }
                self.telemetry = sample
                // Track the car until the driver takes the slider.
                if self.usesLiveSoc,
                   sample.connectionState == .connected,
                   let soc = sample.socDisplay ?? sample.socBms {
                    self.departureSoc = soc
                }
            }
            .store(in: &cancellables)

        services.preferences.preferences
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.preferences = $0 }
            .store(in: &cancellables)

        services.entitlement.isPro
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.isPro = $0 }
            .store(in: &cancellables)

        services.chargers.servingCachedData
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] in self?.chargersAreCached = $0 }
            .store(in: &cancellables)

        NetworkMonitor.shared.online
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.isOffline = !$0 }
            .store(in: &cancellables)

        preferences = services.userPreferences
        isPro = services.isPro
        arrivalReserve = preferences.targetArrivalSocPercent
        reloadSaved()
    }

    var canPlan: Bool {
        origin.selected != nil && destination.selected != nil && !isPlanning
    }

    /// Every routed point in order: origin, stopovers, destination.
    private var routeStops: [LatLon] {
        ([origin.selected] + waypoints.map(\.selected) + [destination.selected])
            .compactMap { $0?.location }
    }

    // MARK: - Slots

    func endpoint(for slot: Slot) -> Endpoint {
        switch slot {
        case .origin: return origin
        case .destination: return destination
        case .waypoint(let index): return waypoints.indices.contains(index) ? waypoints[index] : Endpoint()
        }
    }

    func setQuery(_ text: String, for slot: Slot) {
        // SwiftUI writes the binding back when the value changes underneath the
        // field, so filling a slot in code — Current location, a favourite, a saved
        // trip — arrived here as if the driver had typed it, and the label was sent
        // to the geocoder. That is where "Current location" came back as a place to
        // pick. Compose only calls back on real edits, which is why Android never
        // showed this.
        guard text != endpoint(for: slot).query else { return }
        update(slot) { $0.query = text }
        search(text, slot: slot)
    }

    /// Empties a slot completely — text, the resolved place, and any suggestions.
    /// Clearing only the text would leave `selected` behind, so the field would look
    /// empty while the plan still routed to the old place.
    func clearEndpoint(_ slot: Slot) {
        searchTask?.cancel()
        update(slot) {
            $0.query = ""
            $0.selected = nil
            $0.suggestions = []
            $0.isSearching = false
        }
        activeSlot = nil
        invalidatePlan()
    }

    func addWaypoint() {
        waypoints.append(Endpoint())
    }

    func removeWaypoint(at index: Int) {
        guard waypoints.indices.contains(index) else { return }
        waypoints.remove(at: index)
        invalidatePlan()
    }

    func swapEndpoints() {
        swap(&origin, &destination)
        invalidatePlan()
    }

    private func update(_ slot: Slot, _ mutate: (inout Endpoint) -> Void) {
        switch slot {
        case .origin: mutate(&origin)
        case .destination: mutate(&destination)
        case .waypoint(let index):
            guard waypoints.indices.contains(index) else { return }
            mutate(&waypoints[index])
        }
    }

    // MARK: - Place search

    /// Debounced so typing doesn't fire a request per keystroke — these are billed.
    private func search(_ query: String, slot: Slot) {
        activeSlot = slot
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else {
            update(slot) { $0.suggestions = [] }
            return
        }

        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            await self.runSearch(trimmed, slot: slot)
        }
    }

    private func runSearch(_ query: String, slot: Slot) async {
        update(slot) { $0.isSearching = true }
        defer { update(slot) { $0.isSearching = false } }

        // `??` can't short-circuit an async call, so resolve it explicitly.
        let near: LatLon?
        if let selected = origin.selected {
            near = selected.location
        } else {
            near = await locationProvider.currentLocation()
        }
        do {
            let results = try await services.geocoding.search(query, near: near)
            update(slot) { $0.suggestions = results }
            routingNotice = results.isEmpty ? "No places matched \u{201C}\(query)\u{201D}." : nil
        } catch {
            update(slot) { $0.suggestions = [] }
            routingNotice = error.localizedDescription
        }
    }

    func select(_ place: PlaceResult, for slot: Slot) {
        update(slot) {
            $0.selected = place
            $0.query = place.name
            $0.suggestions = []
        }
        activeSlot = nil
        invalidatePlan()
    }

    func useCurrentLocation() async {
        guard let location = await locationProvider.currentLocation() else {
            errorMessage = "Location unavailable. Check permissions in Settings."
            return
        }
        select(PlaceResult(name: "Current location", location: location), for: .origin)
    }

    /// Uses a nearby charger as the destination — the "drive to this charger" case,
    /// which is otherwise impossible to express through search.
    func setDestination(charger: Charger) {
        select(
            PlaceResult(
                name: charger.name,
                subtitle: charger.operator ?? "",
                location: LatLon(lat: charger.lat, lon: charger.lon)
            ),
            for: .destination
        )
    }

    // MARK: - Planning

    func plan() async {
        guard canPlan else { return }
        isPlanning = true
        errorMessage = nil
        routingNotice = nil
        defer { isPlanning = false }

        do {
            statusMessage = "Finding route…"
            let route = try await services.routing.route(points: routeStops)
            lastRoute = route
            routePoints = route.points
            hasElevationData = route.hasElevationData
            if !route.hasElevationData {
                routingNotice = "This provider reports no elevation, so consumption assumes flat ground. OpenRouteService returns it."
            }

            statusMessage = "Looking for chargers…"
            let chargers = try await services.chargers.chargersAlongRoute(
                routePoints: route.points,
                corridorKm: Double(corridorRadiusKm)
            )
            guard !chargers.isEmpty else {
                errorMessage = "No usable chargers within \(Int(corridorRadiusKm)) km of this route. Try widening the corridor."
                statusMessage = nil
                return
            }
            lastRouteChargers = Self.project(chargers: chargers, onto: route)

            statusMessage = "Planning stops…"
            solve()
        } catch {
            // "Route planning" leads the sentence, and a URLError becomes advice
            // rather than "A server with the specified hostname could not be found."
            errorMessage = error.userMessage(subject: "Route planning")
            statusMessage = nil
        }
    }

    /// Solves against the cached route and charger set, honouring exclusions. Used
    /// by both the initial plan and every re-route, so rejecting a charger costs no
    /// extra routing or charger API calls.
    private func solve() {
        guard let route = lastRoute,
              let originPlace = origin.selected,
              let destinationPlace = destination.selected else { return }

        let candidates = lastRouteChargers.filter { !excludedChargerIds.contains($0.charger.id) }
        guard !candidates.isEmpty else {
            errorMessage = "Every charger on this route has been excluded."
            statusMessage = nil
            return
        }

        let solved = solver.solve(
            origin: originPlace.location,
            destination: destinationPlace.location,
            totalRouteKm: route.distanceKm,
            chargers: candidates,
            params: solverParams,
            userWaypoints: userWaypoints(along: route),
            elevation: route.elevation
        )

        statusMessage = nil
        if let solved {
            plan = solved
            services.activePlan.setPlan(solved)
            services.activePlan.setRoute(route.points)
            errorMessage = nil
        } else {
            errorMessage = excludedChargerIds.isEmpty
                ? "Couldn't find a workable charging plan. Try a higher departure charge or a lower arrival reserve."
                : "No plan works without the excluded chargers. Restore them and try again."
        }
    }

    /// Re-plans around a charger the driver rejected — occupied, closed, or simply
    /// somewhere they'd rather not stop.
    func excludeChargerAndReplan(_ chargerId: String) {
        excludedChargerIds.insert(chargerId)
        solve()
    }

    func restoreExcludedChargers() {
        guard !excludedChargerIds.isEmpty else { return }
        excludedChargerIds.removeAll()
        solve()
    }

    func clearPlan() {
        plan = nil
        routePoints = []
        lastRoute = nil
        lastRouteChargers = []
        excludedChargerIds.removeAll()
        services.activePlan.clearPlan()
    }

    /// A change to the inputs makes the cached route stale.
    private func invalidatePlan() {
        guard plan != nil || lastRoute != nil else { return }
        plan = nil
        lastRoute = nil
        lastRouteChargers = []
        excludedChargerIds.removeAll()
        services.activePlan.clearPlan()
    }

    func setCorridorRadius(_ km: Float) {
        corridorRadiusKm = km
        invalidatePlan()
    }

    func setDepartureSoc(_ soc: Float) {
        usesLiveSoc = false
        departureSoc = soc
    }

    /// Hands the slider back to the car.
    func useLiveSoc() {
        usesLiveSoc = true
        if let soc = telemetry.socDisplay ?? telemetry.socBms { departureSoc = soc }
    }

    var liveSocAvailable: Bool {
        telemetry.connectionState == .connected && (telemetry.socDisplay ?? telemetry.socBms) != nil
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

    /// Stopovers as solver waypoints, placed at their nearest point along the route.
    private func userWaypoints(along route: BaseRoute) -> [UserWaypoint] {
        waypoints.compactMap { endpoint in
            guard let place = endpoint.selected else { return nil }
            let (alongKm, _) = RouteGeo.projectOntoRoute(
                points: route.points,
                lat: place.location.lat,
                lon: place.location.lon,
                totalKm: route.distanceKm
            )
            return UserWaypoint(name: place.name, location: place.location, distanceFromOriginKm: alongKm)
        }
    }

    // MARK: - Saved trips and places

    func reloadSaved() {
        savedTrips = (try? services.savedTrips.all()) ?? []
        favoritePlaces = (try? services.savedPlaces.all()) ?? []
    }

    var canSaveTrip: Bool { origin.selected != nil && destination.selected != nil }

    /// Default name for a saved trip, matching Android.
    var defaultTripName: String {
        let originName = origin.selected?.name ?? "Origin"
        let destinationName = destination.selected?.name ?? "Destination"
        return "\(originName) → \(destinationName)"
    }

    func saveTrip(named name: String) {
        guard let originPlace = origin.selected, let destinationPlace = destination.selected else { return }
        let def = SavedTripDef(
            origin: SavedPlaceDef(name: originPlace.name, lat: originPlace.location.lat, lon: originPlace.location.lon),
            destination: SavedPlaceDef(
                name: destinationPlace.name,
                lat: destinationPlace.location.lat,
                lon: destinationPlace.location.lon
            ),
            waypoints: waypoints.compactMap(\.selected).map {
                SavedPlaceDef(name: $0.name, lat: $0.location.lat, lon: $0.location.lon)
            },
            arrivalSocTarget: arrivalReserve
        )
        _ = try? services.savedTrips.save(name: name, def: def)
        reloadSaved()
    }

    func loadTrip(_ trip: SavedTrip) {
        let def = trip.def
        origin = Endpoint(query: def.origin.name, selected: PlaceResult(
            name: def.origin.name, location: LatLon(lat: def.origin.lat, lon: def.origin.lon)
        ))
        destination = Endpoint(query: def.destination.name, selected: PlaceResult(
            name: def.destination.name, location: LatLon(lat: def.destination.lat, lon: def.destination.lon)
        ))
        waypoints = def.waypoints.map { stop in
            Endpoint(query: stop.name, selected: PlaceResult(
                name: stop.name, location: LatLon(lat: stop.lat, lon: stop.lon)
            ))
        }
        arrivalReserve = def.arrivalSocTarget
        invalidatePlan()
    }

    func deleteTrip(_ trip: SavedTrip) {
        try? services.savedTrips.delete(id: trip.id)
        reloadSaved()
    }

    func toggleFavorite(_ place: PlaceResult) {
        try? services.savedPlaces.toggleFavorite(name: place.name, location: place.location)
        reloadSaved()
    }

    func isFavorite(_ place: PlaceResult?) -> Bool {
        guard let place else { return false }
        return favoritePlaces.contains {
            abs($0.lat - place.location.lat) < 0.0001 && abs($0.lon - place.location.lon) < 0.0001
        }
    }

    func selectFavorite(_ favorite: SavedPlaceEntity, for slot: Slot) {
        select(
            PlaceResult(name: favorite.name, location: LatLon(lat: favorite.lat, lon: favorite.lon)),
            for: slot
        )
    }

    /// Drops a saved place into a stopover slot, reusing a blank one the driver has
    /// already added rather than leaving an empty field behind it.
    func addFavoriteAsWaypoint(_ favorite: SavedPlaceEntity) {
        let blank = waypoints.firstIndex { $0.selected == nil && $0.query.trimmingCharacters(in: .whitespaces).isEmpty }
        let index: Int
        if let blank {
            index = blank
        } else {
            addWaypoint()
            index = waypoints.count - 1
        }
        selectFavorite(favorite, for: .waypoint(index))
    }

    func renameFavorite(_ favorite: SavedPlaceEntity, to newName: String) {
        try? services.savedPlaces.rename(id: favorite.id, to: newName)
        // Saved trips embed a copy of the place name, so keep them in sync.
        _ = try? services.savedTrips.renamePlace(lat: favorite.lat, lon: favorite.lon, to: newName)
        renameSelectedEndpoints(lat: favorite.lat, lon: favorite.lon, to: newName)
        reloadSaved()
    }

    /// Relabels any slot currently holding the renamed place, so the fields on screen
    /// do not keep showing the old name.
    private func renameSelectedEndpoints(lat: Double, lon: Double, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        func rename(_ endpoint: inout Endpoint) {
            guard let selected = endpoint.selected,
                  abs(selected.location.lat - lat) < 0.0001,
                  abs(selected.location.lon - lon) < 0.0001
            else { return }
            endpoint.selected = PlaceResult(
                name: trimmed,
                subtitle: selected.subtitle,
                location: selected.location
            )
            endpoint.query = trimmed
        }

        rename(&origin)
        rename(&destination)
        for index in waypoints.indices { rename(&waypoints[index]) }
    }

    func deleteFavorite(_ favorite: SavedPlaceEntity) {
        try? services.savedPlaces.deletePlace(id: favorite.id)
        reloadSaved()
    }

    // MARK: - Nearby chargers

    /// Only runs once location is already authorized — opening the tab must not
    /// trigger the permission prompt.
    func loadNearbyChargers() async {
        guard locationProvider.isAuthorized else { return }
        guard let center = await locationProvider.currentLocation() else { return }
        nearbyChargers = (try? await services.chargers.chargersNear(center: center, radiusKm: 25)) ?? []
        await loadNearbyAvailability(center: center)
    }

    func clearNearbyChargers() {
        nearbyChargers = []
        chargerAvailability = [:]
    }

    /// Live connector availability for the nearby list.
    ///
    /// One Places request for the whole radius, not one per charger — it bills the
    /// user's key, so the cost stays flat regardless of how many chargers are
    /// listed. Requires Pro and a Google key; without them the rows simply carry no
    /// status, which is honest rather than a guess.
    private func loadNearbyAvailability(center: LatLon) async {
        chargerAvailability = [:]
        guard isPro, let key = preferences.googleMapsApiKey, !key.isEmpty else { return }
        guard let snapshot = try? await services.occupancy.occupancyNear(
            center, radiusM: 25_000, apiKey: key
        ) else { return }

        // Places and Open Charge Map name the same site differently, so match on a
        // normalised containment rather than equality, and leave anything ambiguous
        // without status.
        var matched: [String: ChargerAvailability] = [:]
        for charger in nearbyChargers {
            let name = Self.normalized(charger.name)
            guard !name.isEmpty else { continue }
            let hit = snapshot.stations.first {
                let station = Self.normalized($0.name)
                return station == name || station.contains(name) || name.contains(station)
            }
            guard let hit, hit.totalCount > 0 else { continue }
            matched[charger.id] = ChargerAvailability(
                available: hit.availableCount,
                total: hit.totalCount
            )
        }
        chargerAvailability = matched
    }

    private static func normalized(_ name: String) -> String {
        name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    func dismissRoutingNotice() { routingNotice = nil }

    // MARK: - Geometry

    /// Places each charger along the route by nearest sampled point, and measures
    /// the detour as the straight-line hop off the corridor.
    private static func project(chargers: [Charger], onto route: BaseRoute) -> [RouteCharger] {
        guard !route.points.isEmpty else { return [] }
        return chargers.map { charger in
            let (alongKm, detourKm) = RouteGeo.projectOntoRoute(
                points: route.points,
                lat: charger.lat,
                lon: charger.lon,
                totalKm: route.distanceKm
            )
            return RouteCharger(charger: charger, distanceAlongRouteKm: alongKm, detourKm: detourKm)
        }
        .sorted { $0.distanceAlongRouteKm < $1.distanceAlongRouteKm }
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
