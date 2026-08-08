import Combine
import CoreDomain
import Foundation
import MapKit
import SwiftData

/// Repository for charger data — Open Charge Map or Google Places fetch, plus a
/// local cache with a 7-day TTL shared by both.
public final class ChargerRepository: @unchecked Sendable {
    private let modelContext: ModelContext
    /// Read per request, not captured at init: the user can paste a key into
    /// Settings at any time and the next lookup must pick it up.
    private let apiKey: @Sendable () -> String
    /// Which source to fetch from, and the Google key behind the Places option.
    /// Both are closures for the same reason as `apiKey`.
    private let source: @Sendable () -> ChargerSource
    private let googleApiKey: @Sendable () -> String
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private let _servingCachedData = CurrentValueSubject<Bool, Never>(false)
    public var servingCachedData: AnyPublisher<Bool, Never> {
        _servingCachedData.eraseToAnyPublisher()
    }

    /// Set by `noteSourceChanged()`; the next `loadArea` re-fetches from the new
    /// source instead of trusting rows written by the previous one.
    private let _sourceChanged = CurrentValueSubject<Bool, Never>(false)

    private static let cacheTTL: TimeInterval = 7 * 24 * 60 * 60

    private static let connectorMap: [Int: ConnectorType] = [
        33: .ccs2,
        32: .ccs1,
        2: .chademo,
        25: .type2,
        1036: .type2,
        27: .teslaSupercharger,
        30: .nacs
    ]

    /// Google's EV connector vocabulary. `EV_CONNECTOR_TYPE_TESLA` is the pre-NACS
    /// spelling and still appears, so both land on the same pair of cases.
    private static let googleConnectorMap: [String: ConnectorType] = [
        "EV_CONNECTOR_TYPE_CCS_COMBO_1": .ccs1,
        "EV_CONNECTOR_TYPE_CCS_COMBO_2": .ccs2,
        "EV_CONNECTOR_TYPE_CHADEMO": .chademo,
        "EV_CONNECTOR_TYPE_TYPE_2": .type2,
        "EV_CONNECTOR_TYPE_NACS": .nacs,
        "EV_CONNECTOR_TYPE_TESLA": .teslaSupercharger
    ]

    /// Keep the public nearby search aligned with Android: Google Places returns at
    /// most 20 results per circle, so the search circle must match the requested
    /// area before the final distance filter is applied.
    public static let nearbyRadiusKm: Double = 10.0
    /// The in-car surface uses the same wider pool as Android Auto.
    public static let inCarRadiusKm: Double = 25.0
    private static let googleDefaultTileRadiusKm: Double = 10.0
    private static let googleMaxTileRadiusKm: Double = 50.0
    private static let googleMaxTiles = 16
    private static let googleMaxResults = 20

    public init(
        modelContext: ModelContext,
        apiKey: @escaping @Sendable () -> String,
        source: @escaping @Sendable () -> ChargerSource = { .openChargeMap },
        googleApiKey: @escaping @Sendable () -> String = { "" },
        session: URLSession = NetworkSession.shared
    ) {
        self.modelContext = modelContext
        self.apiKey = apiKey
        self.source = source
        self.googleApiKey = googleApiKey
        self.session = session
    }

    // MARK: - Public API

    /// The canonical phone-sized nearby search, matching Android's 10 km lookup.
    public func chargersNearby(center: LatLon) async throws -> [Charger] {
        try await chargersNear(center: center, radiusKm: Self.nearbyRadiusKm)
    }

    /// The canonical in-car nearby search, matching Android Auto's 25 km pool.
    public func chargersForInCar(center: LatLon) async throws -> [Charger] {
        try await chargersNear(center: center, radiusKm: Self.inCarRadiusKm)
    }

    public func chargersNear(center: LatLon) async throws -> [Charger] {
        try await chargersNear(center: center, radiusKm: Self.nearbyRadiusKm)
    }

    /// Generic radius search for route/destination-specific consumers.
    public func chargersNear(center: LatLon, radiusKm: Double) async throws -> [Charger] {
        let dLat = radiusKm / 111.0
        let dLon = radiusKm / (111.0 * max(cos(center.lat * .pi / 180.0), 0.2))
        let chargers = try await loadArea(
            minLat: center.lat - dLat, minLon: center.lon - dLon,
            maxLat: center.lat + dLat, maxLon: center.lon + dLon,
            // Google Places tiles this exact box using the same policy as Android.
            appleCenters: [center]
        )
        return chargers
            .filter { !$0.isRestricted && approxDistanceKm(center, LatLon(lat: $0.lat, lon: $0.lon)) <= radiusKm }
            .sorted { approxDistanceKm(center, LatLon(lat: $0.lat, lon: $0.lon)) < approxDistanceKm(center, LatLon(lat: $1.lat, lon: $1.lon)) }
    }

    public func chargersAlongRoute(routePoints: [LatLon], corridorKm: Double = 5.0) async throws -> [Charger] {
        guard !routePoints.isEmpty else { return [] }
        let minLat = routePoints.map(\.lat).min()! - corridorKm / 111.0
        let maxLat = routePoints.map(\.lat).max()! + corridorKm / 111.0
        let minLon = routePoints.map(\.lon).min()! - corridorKm / 85.0
        let maxLon = routePoints.map(\.lon).max()! + corridorKm / 85.0

        let chargers = try await loadArea(
            minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon,
            // Follow the road rather than tiling the whole bounding box: a route's
            // box is mostly empty countryside, and every tile is a billed request.
            appleCenters: sampleAlongRoute(routePoints)
        )
        return chargers.filter { charger in
            !charger.isRestricted && routePoints.contains { p in
                approxDistanceKm(p, LatLon(lat: charger.lat, lon: charger.lon)) <= corridorKm
            }
        }
    }

    public func clearCache() throws {
        let descriptor = FetchDescriptor<ChargerEntity>()
        let all = try modelContext.fetch(descriptor)
        for entity in all { modelContext.delete(entity) }
        try modelContext.save()
    }

    /// Marks all cached rows as suspect because the charger source changed: the
    /// next area load must re-fetch from the new provider. Non-destructive — the
    /// old provider's rows stay as a fallback if the new one can't be reached,
    /// so a source switch never leaves the user with an empty charger list.
    public func noteSourceChanged() {
        _sourceChanged.value = true
    }

    // MARK: - Private

    private func loadArea(
        minLat: Double,
        minLon: Double,
        maxLat: Double,
        maxLon: Double,
        appleCenters: [LatLon]
    ) async throws -> [Charger] {
        let prefixes = Geohash.coveringPrefixes(minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon, precision: 4)
        let now = Date()
        let currentSource = source()
        let wantedPrefixes = Self.sourcePrefixes(currentSource)
        // A source switch forces the next fetch even when rows look fresh.
        let sourceChanged = _sourceChanged.value
        _sourceChanged.value = false

        let cached = try cachedInBox(prefixes: prefixes, minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon)
        let currentSourceRows = cached.filter { entity in
            wantedPrefixes.contains { entity.id.hasPrefix($0) }
        }
        let freshest = currentSourceRows.map(\.cachedAt).max()
        let stale = sourceChanged ||
            freshest == nil ||
            now.timeIntervalSince(freshest!) > Self.cacheTTL

        var refreshError: (any Error)?
        if stale {
            do {
                switch currentSource {
                case .openChargeMap:
                    try await refreshArea(minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon)
                case .googlePlaces:
                    try await refreshGooglePlaces(
                        minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon
                    )
                case .appleMaps:
                    try await refreshAppleMaps(centers: appleCenters)
                case .combined:
                    // OCM and Apple Maps are independent providers: if OCM
                    // fails, Apple Maps can still fill the box so the user
                    // isn't left with nothing.
                    do { try await refreshArea(minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon) }
                    catch { refreshError = error }
                    try await refreshAppleMaps(centers: appleCenters)
                }
                // Deduplicate combined results: Apple Maps duplicates close to OCM
                // entries are removed, keeping OCM's richer data.
                if currentSource == .combined {
                    try deduplicateCombined()
                }
            } catch {
                // Cached data is better than an error: hold this and only throw
                // if there is genuinely nothing left to show.
                refreshError = error
            }
        }

        if let refreshError {
            // Refresh failed: fall back to whatever is cached (including the
            // previous source's rows) so the list never blanks out. The banner
            // is driven by `servingCachedData`, which the failed refresh set.
            let after = try cachedInBox(prefixes: prefixes, minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon)
            let preferred = after.filter { entity in
                wantedPrefixes.contains { entity.id.hasPrefix($0) }
            }
            let fallback = preferred.isEmpty ? after : preferred
            if fallback.isEmpty { throw refreshError }
            return fallback.map(entityToDomain)
        }

        // Clean refresh (or fresh cache): the current source's rows are the
        // truth, and any other provider's leftover rows stay hidden.
        _servingCachedData.value = false
        let fresh = try cachedInBox(prefixes: prefixes, minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon)
        return fresh
            .filter { entity in wantedPrefixes.contains { entity.id.hasPrefix($0) } }
            .map(entityToDomain)
    }

    /// All cached rows inside the box, deduplicated by id.
    private func cachedInBox(
        prefixes: Set<String>,
        minLat: Double,
        minLon: Double,
        maxLat: Double,
        maxLon: Double
    ) throws -> [ChargerEntity] {
        var seen = Set<String>()
        var rows: [ChargerEntity] = []
        for prefix in prefixes {
            for entity in try byGeohashPrefix(prefix) {
                guard !seen.contains(entity.id) else { continue }
                guard entity.lat >= minLat && entity.lat <= maxLat && entity.lon >= minLon && entity.lon <= maxLon else { continue }
                seen.insert(entity.id)
                rows.append(entity)
            }
        }
        return rows
    }

    /// The id prefixes a source writes to the cache, used to show only the
    /// current source's rows once its refresh has succeeded.
    private static func sourcePrefixes(_ source: ChargerSource) -> [String] {
        switch source {
        case .openChargeMap: return ["ocm-"]
        case .googlePlaces: return ["gp-"]
        case .appleMaps: return ["apple-"]
        case .combined: return ["ocm-", "apple-"]
        }
    }

    private func byGeohashPrefix(_ prefix: String) throws -> [ChargerEntity] {
        let descriptor = FetchDescriptor<ChargerEntity>(
            predicate: #Predicate { $0.geohash.starts(with: prefix) }
        )
        return try modelContext.fetch(descriptor)
    }

    private func refreshArea(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double) async throws {
        let key = apiKey().trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else {
            _servingCachedData.value = true
            throw ChargerError.missingApiKey
        }

        var components = URLComponents(string: "https://api.openchargemap.io/v3/poi/")!
        components.queryItems = [
            .init(name: "output", value: "json"),
            .init(name: "maxresults", value: "500"),
            .init(name: "boundingbox", value: "(\(minLat),\(minLon)),(\(maxLat),\(maxLon))"),
            .init(name: "key", value: key)
        ]
        guard let url = components.url else { throw ChargerError.badRequest }

        do {
            let (data, response) = try await session.dataWithRetry(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                _servingCachedData.value = true
                throw ChargerError.httpStatus(http.statusCode)
            }
            let pois = try decoder.decode([OCMPoi].self, from: data)
            let now = Date()

            for poi in pois {
                guard let entity = poiToEntity(poi, now: now) else { continue }
                modelContext.insert(entity)
            }
            try modelContext.save()
            _servingCachedData.value = false
        } catch let error as ChargerError {
            throw error
        } catch {
            _servingCachedData.value = true
            throw ChargerError.transport(error)
        }
    }

    // MARK: - Google Places

    /// Thins a route down to the Apple Maps search centres worth querying.
    ///
    /// Tiles overlap slightly at this spacing so a charger sitting between two
    /// samples is still inside one of them. Long routes are decimated to the
    /// provider request ceiling rather than refused.
    private func sampleAlongRoute(_ points: [LatLon]) -> [LatLon] {
        guard let first = points.first else { return [] }
        let spacingKm = Self.googleDefaultTileRadiusKm * 1.6

        var centers: [LatLon] = [first]
        for point in points.dropFirst() {
            guard let last = centers.last else { break }
            if approxDistanceKm(last, point) >= spacingKm { centers.append(point) }
        }
        if let last = points.last, centers.last.map({ approxDistanceKm($0, last) > spacingKm / 2 }) == true {
            centers.append(last)
        }

        guard centers.count > Self.googleMaxTiles else { return centers }
        // Keep the ends and spread the rest evenly, so the thinning shows up as
        // coarser coverage over the whole route rather than a truncated one.
        let stride = Double(centers.count - 1) / Double(Self.googleMaxTiles - 1)
        return (0..<Self.googleMaxTiles).map { centers[Int((Double($0) * stride).rounded())] }
    }

    private struct GoogleTile {
        let center: LatLon
        let radiusM: Double
    }

    /// Same tiling policy as Android's PlacesChargerSource. A 10 km nearby box
    /// produces one 10 km circle; larger areas grow the circle until no more than
    /// 16 billed requests are needed, capped by Places' 50 km limit.
    private func googleTiles(
        minLat: Double,
        minLon: Double,
        maxLat: Double,
        maxLon: Double
    ) -> [GoogleTile] {
        let midLat = (minLat + maxLat) / 2
        let kmPerLon = 111.0 * max(cos(midLat * .pi / 180), 0.2)
        let heightKm = max((maxLat - minLat) * 111.0, 0.001)
        let widthKm = max((maxLon - minLon) * kmPerLon, 0.001)

        var radiusKm = Self.googleDefaultTileRadiusKm
        while radiusKm < Self.googleMaxTileRadiusKm &&
                googleTileCount(widthKm: widthKm, heightKm: heightKm, radiusKm: radiusKm) > Self.googleMaxTiles {
            radiusKm = min(radiusKm * 1.5, Self.googleMaxTileRadiusKm)
        }

        let stepKm = radiusKm * sqrt(2.0)
        let columns = max(Int(ceil(widthKm / stepKm)), 1)
        let rows = max(Int(ceil(heightKm / stepKm)), 1)
        let latStep = (maxLat - minLat) / Double(rows)
        let lonStep = (maxLon - minLon) / Double(columns)

        return (0..<rows).flatMap { row in
            (0..<columns).map { column in
                GoogleTile(
                    center: LatLon(
                        lat: minLat + latStep * (Double(row) + 0.5),
                        lon: minLon + lonStep * (Double(column) + 0.5)
                    ),
                    radiusM: radiusKm * 1000.0
                )
            }
        }.prefix(Self.googleMaxTiles).map { $0 }
    }

    private func googleTileCount(widthKm: Double, heightKm: Double, radiusKm: Double) -> Int {
        let stepKm = radiusKm * sqrt(2.0)
        return max(Int(ceil(widthKm / stepKm)), 1) * max(Int(ceil(heightKm / stepKm)), 1)
    }

    private func refreshGooglePlaces(
        minLat: Double,
        minLon: Double,
        maxLat: Double,
        maxLon: Double
    ) async throws {
        let key = googleApiKey().trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else {
            _servingCachedData.value = true
            throw ChargerError.missingGoogleKey
        }
        let now = Date()
        var inserted = 0
        var lastError: (any Error)?

        for tile in googleTiles(minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon) {
            do {
                inserted += try await fetchGoogleCircle(
                    center: tile.center, radiusM: tile.radiusM, key: key, now: now
                )
            } catch {
                // One tile failing shouldn't discard the tiles that worked.
                lastError = error
            }
        }

        if inserted == 0, let lastError {
            _servingCachedData.value = true
            throw lastError
        }
        try modelContext.save()
        _servingCachedData.value = false
    }

    private func fetchGoogleCircle(
        center: LatLon,
        radiusM: Double,
        key: String,
        now: Date
    ) async throws -> Int {
        var request = URLRequest(url: URL(string: "https://places.googleapis.com/v1/places:searchNearby")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "X-Goog-Api-Key")
        // The field mask decides the billing SKU. `evChargeOptions` is what makes
        // these places usable as chargers rather than pins on a map.
        request.setValue(
            "places.id,places.displayName,places.formattedAddress,places.location,places.evChargeOptions,places.businessStatus",
            forHTTPHeaderField: "X-Goog-FieldMask"
        )
        request.httpBody = try encoder.encode(PlacesNearbyRequest(
            includedTypes: ["electric_vehicle_charging_station"],
            maxResultCount: Self.googleMaxResults,
            locationRestriction: .init(circle: .init(
                center: .init(latitude: center.lat, longitude: center.lon),
                radius: radiusM
            ))
        ))

        do {
            PlacesUsageCounter.shared.record()
            let (data, response) = try await session.dataWithRetry(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw ChargerError.googleHttpStatus(http.statusCode)
            }
            let decoded = try decoder.decode(PlacesNearbyResponse.self, from: data)
            var count = 0
            for place in decoded.places {
                guard let entity = placeToEntity(place, now: now) else { continue }
                modelContext.insert(entity)
                count += 1
            }
            return count
        } catch let error as ChargerError {
            throw error
        } catch {
            throw ChargerError.transport(error)
        }
    }

    private func placeToEntity(_ place: PlacesNearbyResponse.Place, now: Date) -> ChargerEntity? {
        guard let id = place.id,
              let lat = place.location?.latitude,
              let lon = place.location?.longitude
        else { return nil }

        let aggregation = place.evChargeOptions?.connectorAggregation ?? []
        let connectors: [Connector] = aggregation.compactMap { entry in
            guard let type = entry.type.flatMap({ Self.googleConnectorMap[$0] }) else { return nil }
            return Connector(
                type: type,
                powerKw: Float(entry.maxChargeRateKw ?? 0),
                count: entry.count ?? 1
            )
        }
        let connectorsJson = (try? encoder.encode(connectors)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        return ChargerEntity(
            id: "gp-\(id)",
            name: place.displayName?.text ?? "Charger",
            address: place.formattedAddress,
            lat: lat,
            lon: lon,
            geohash: Geohash.encode(lat: lat, lon: lon, precision: 6),
            maxPowerKw: connectors.map(\.powerKw).max() ?? 0,
            connectorsJson: connectorsJson,
            // Places reports no network operator, price or access policy, so those
            // stay empty rather than being guessed at.
            operator: nil,
            isOperational: place.businessStatus.map { $0 == "OPERATIONAL" } ?? true,
            pricePerKwh: nil,
            cachedAt: now,
            isRestricted: false,
            usageTypeId: nil,
            usageCost: nil
        )
    }

    // MARK: - Errors

public enum ChargerError: LocalizedError {
    case missingApiKey
    case missingGoogleKey
    case badRequest
    case httpStatus(Int)
    case googleHttpStatus(Int)
    case transport(any Error)

    public var errorDescription: String? {
        switch self {
        case .missingApiKey:
            return "Add an Open Charge Map key in Settings to look up chargers."
        case .missingGoogleKey:
            return "Add a Google Maps key in Settings to look up chargers with Google Places."
        case .googleHttpStatus(let code) where code == 401 || code == 403:
            return "Google rejected the key. Check that the Places API (New) is enabled for it."
        case .googleHttpStatus(let code):
            return "Google Places returned an error (HTTP \(code))."
        case .badRequest:
            return "Could not build the charger request."
        case .httpStatus(let code) where code == 401 || code == 403:
            return "Open Charge Map rejected the key. Check it in Settings."
        case .httpStatus(let code):
            return "Charger database returned an error (HTTP \(code))."
        case .transport(let error):
            // The underlying URLError becomes advice ("you appear to be offline")
            // rather than Foundation's hostname-resolution wording.
            return error.userMessage(subject: "Charger search")
        }
    }
}

// MARK: - Mapping

    private func poiToEntity(_ poi: OCMPoi, now: Date) -> ChargerEntity? {
        guard let id = poi.ID,
              let lat = poi.AddressInfo?.Latitude,
              let lon = poi.AddressInfo?.Longitude
        else { return nil }

        let connections = poi.Connections ?? []
        let connectors: [Connector] = connections.compactMap { c in
            guard let type = Self.connectorMap[c.ConnectionTypeID ?? -1] else { return nil }
            return Connector(type: type, powerKw: Float(c.PowerKW ?? 0), count: c.Quantity ?? 1)
        }

        let connectorsJson = (try? encoder.encode(connectors)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let maxPower = connections.compactMap(\.PowerKW).max() ?? 0
        let isRestricted = ChargerAccess.isRestricted(
            usageTypeId: poi.UsageType?.ID,
            isAccessKeyRequired: poi.UsageType?.IsAccessKeyRequired,
            name: poi.AddressInfo?.Title
        )

        // Build address from OCM AddressInfo fields
        let addressLine1 = poi.AddressInfo?.AddressLine1
        let town = poi.AddressInfo?.Town
        let address: String? = {
            switch (addressLine1, town) {
            case let (a?, t?): return "\(a), \(t)"
            case let (a?, nil): return a
            case let (nil, t?): return t
            case (nil, nil): return nil
            }
        }()

        return ChargerEntity(
            id: "ocm-\(id)",
            name: poi.AddressInfo?.Title ?? "Charger",
            address: address,
            lat: lat,
            lon: lon,
            geohash: Geohash.encode(lat: lat, lon: lon, precision: 6),
            maxPowerKw: Float(maxPower),
            connectorsJson: connectorsJson,
            operator: poi.OperatorInfo?.Title,
            isOperational: poi.StatusType?.IsOperational ?? true,
            pricePerKwh: parsePricePerKwh(poi.UsageCost),
            cachedAt: now,
            isRestricted: isRestricted,
            usageTypeId: poi.UsageType?.ID,
            usageCost: poi.UsageCost
        )
    }

    private func entityToDomain(_ entity: ChargerEntity) -> Charger {
        let connectors: [Connector] = {
            if let data = entity.connectorsJson.data(using: .utf8),
               let decoded = try? decoder.decode([Connector].self, from: data) {
                return decoded
            }
            return []
        }()

        return Charger(
            id: entity.id,
            name: entity.name,
            address: entity.address,
            lat: entity.lat,
            lon: entity.lon,
            connectors: connectors,
            maxPowerKw: entity.maxPowerKw,
            operator: entity.operator,
            isOperational: entity.isOperational,
            pricePerKwh: entity.pricePerKwh,
            lastVerified: entity.cachedAt,
            // Re-evaluated on read so rows cached under an older rule are corrected
            // immediately rather than after the 7-day TTL expires.
            isRestricted: entity.isRestricted || ChargerAccess.isRestricted(
                usageTypeId: entity.usageTypeId,
                isAccessKeyRequired: nil,
                name: entity.name
            ),
            usageCost: entity.usageCost,
            hasLiveStatus: entity.hasLiveStatus
        )
    }

    // MARK: - Helpers

    /// Best-effort parse of an OCM cost string like "£0.45/kWh" → 0.45.
    private func parsePricePerKwh(_ cost: String?) -> Float? {
        guard let cost, !cost.isEmpty else { return nil }
        if cost.localizedCaseInsensitiveContains("free") { return 0 }

        let pattern = #"([\d.]+)\s*(?:€|\$|£|USD|EUR|GBP)?.*kwh"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(cost.startIndex..., in: cost)
        guard let match = regex.firstMatch(in: cost, range: range),
              let captureRange = Range(match.range(at: 1), in: cost)
        else { return nil }
        return Float(cost[captureRange])
    }

    public func approxDistanceKm(_ a: LatLon, _ b: LatLon) -> Double {
        let dLat = (a.lat - b.lat) * 111.0
        let dLon = (a.lon - b.lon) * 111.0 * cos((a.lat + b.lat) / 2 * .pi / 180.0)
        return sqrt(dLat * dLat + dLon * dLon)
    }

    // MARK: - Apple Maps

    /// Searches for EV chargers near each centre point via MKLocalSearch and
    /// persists results (name, address, location only — Apple's POI data has
    /// no pricing, connector type or operator information).
    private func refreshAppleMaps(centers: [LatLon]) async throws {
        let now = Date()
        var inserted = 0
        for center in centers {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = "EV charger"
            request.region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: center.lat, longitude: center.lon),
                latitudinalMeters: 30_000,
                longitudinalMeters: 30_000
            )
            request.resultTypes = [.pointOfInterest]
            let search = MKLocalSearch(request: request)
            let response = try? await search.start()
            guard let items = response?.mapItems else { continue }
            for item in items {
                guard let loc = item.placemark.location else { continue }
                let lat = loc.coordinate.latitude
                let lon = loc.coordinate.longitude
                let name = item.name ?? "EV Charger"
                // Build the address from the placemark the way OCM does
                // ("Street, Town"): Apple's POI results carry full address
                // fields, so storing nil here hides them from every list row.
                let address = Self.appleAddress(from: item.placemark)
                let id = "apple-\(Geohash.encode(lat: lat, lon: lon, precision: 10))"
                // Skip if already cached (dedup across tiles and future refreshes).
                // Backfill the address when a cached entry lacks one — older
                // Apple Maps entries were stored with address: nil and would
                // otherwise never show a street address until the cache cleared.
                let existing = try modelContext.fetch(
                    FetchDescriptor<ChargerEntity>(
                        predicate: #Predicate { $0.id == id }
                    )
                )
                if let cached = existing.first {
                    if cached.address == nil, let address {
                        cached.address = address
                        cached.cachedAt = now
                    }
                    continue
                }
                let entity = ChargerEntity(
                    id: id,
                    name: name,
                    address: address,
                    lat: lat,
                    lon: lon,
                    geohash: Geohash.encode(lat: lat, lon: lon, precision: 6),
                    maxPowerKw: 0,
                    connectorsJson: "[]",
                    operator: nil,
                    isOperational: true,
                    pricePerKwh: nil,
                    cachedAt: now,
                    isRestricted: false,
                    usageTypeId: nil,
                    usageCost: nil
                )
                modelContext.insert(entity)
                inserted += 1
            }
        }
        print("[ChargerRepo] Apple Maps: \(inserted) chargers found near \(centers.count) centre(s)")
        try modelContext.save()
    }

    /// Formats an address from an Apple Maps placemark. MKPlacemark splits the
    /// address into structured fields, so this joins the street and city the
    /// same way the OCM path does — no street or city means no address.
    private static func appleAddress(from placemark: MKPlacemark) -> String? {
        var parts: [String] = []
        if let number = placemark.subThoroughfare, !number.isEmpty {
            parts.append(number)
        }
        if let street = placemark.thoroughfare, !street.isEmpty {
            parts.append(street)
        }
        if let city = placemark.locality, !city.isEmpty {
            parts.append(city)
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Removes Apple Maps entries that are within 200m of an OCM entry.
    /// OCM has richer data (pricing, connectors), so Apple Maps duplicates
    /// are dropped to keep results clean.
    private func deduplicateCombined() throws {
        let all = try modelContext.fetch(FetchDescriptor<ChargerEntity>())
        let ocm = all.filter { $0.id.hasPrefix("ocm-") }
        let apple = all.filter { $0.id.hasPrefix("apple-") }
        var toDelete = Set<ChargerEntity>()
        for a in apple {
            for o in ocm {
                let d = approxDistanceKm(
                    LatLon(lat: a.lat, lon: a.lon),
                    LatLon(lat: o.lat, lon: o.lon)
                )
                if d < 0.2 { // 200m
                    toDelete.insert(a)
                    break
                }
            }
        }
        for entity in toDelete {
            modelContext.delete(entity)
        }
        if !toDelete.isEmpty {
            print("[ChargerRepo] Dedup: removed \(toDelete.count) Apple Maps chargers near OCM entries")
        }
        try modelContext.save()
    }
}

// MARK: - Google Places API Models

private struct PlacesNearbyRequest: Encodable {
    struct LocationRestriction: Encodable {
        struct Circle: Encodable {
            struct Center: Encodable {
                let latitude: Double
                let longitude: Double
            }
            let center: Center
            let radius: Double
        }
        let circle: Circle
    }

    let includedTypes: [String]
    let maxResultCount: Int
    let locationRestriction: LocationRestriction
}

private struct PlacesNearbyResponse: Decodable {
    struct Place: Decodable {
        struct DisplayName: Decodable { let text: String? }
        struct Location: Decodable {
            let latitude: Double?
            let longitude: Double?
        }
        struct EvChargeOptions: Decodable {
            struct ConnectorAggregation: Decodable {
                let type: String?
                let maxChargeRateKw: Double?
                let count: Int?
                let availableCount: Int?
            }
            let connectorCount: Int?
            let connectorAggregation: [ConnectorAggregation]?
        }

        let id: String?
        let displayName: DisplayName?
        let formattedAddress: String?
        let location: Location?
        let evChargeOptions: EvChargeOptions?
        let businessStatus: String?
    }

    let places: [Place]

    private enum CodingKeys: String, CodingKey { case places }

    /// Places omits the array entirely when nothing matches.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        places = try container.decodeIfPresent([Place].self, forKey: .places) ?? []
    }
}

// MARK: - OCM API Models

private struct OCMPoi: Codable {
    let ID: Int?
    let AddressInfo: OCMAddressInfo?
    let Connections: [OCMConnection]?
    let OperatorInfo: OCMOperatorInfo?
    let StatusType: OCMStatusType?
    let UsageType: OCMUsageType?
    let UsageCost: String?
}

private struct OCMAddressInfo: Codable {
    let Title: String?
    let AddressLine1: String?
    let Town: String?
    let Latitude: Double?
    let Longitude: Double?
}

private struct OCMConnection: Codable {
    let ConnectionTypeID: Int?
    let PowerKW: Double?
    let Quantity: Int?
}

private struct OCMOperatorInfo: Codable {
    let Title: String?
}

private struct OCMStatusType: Codable {
    let IsOperational: Bool?
}

private struct OCMUsageType: Codable {
    let ID: Int?
    let IsAccessKeyRequired: Bool?
}
