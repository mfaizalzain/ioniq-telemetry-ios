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

    /// Places caps a nearby search at 50 km and 20 results, so an area is covered
    /// by tiled circles. Each tile is one billed request, hence the ceiling.
    private static let googleTileRadiusM: Double = 15_000
    private static let googleMaxTiles = 12
    private static let googleMaxResults = 20

    public init(
        modelContext: ModelContext,
        apiKey: @escaping @Sendable () -> String,
        source: @escaping @Sendable () -> ChargerSource = { .openChargeMap },
        googleApiKey: @escaping @Sendable () -> String = { "" }
    ) {
        self.modelContext = modelContext
        self.apiKey = apiKey
        self.source = source
        self.googleApiKey = googleApiKey
        self.session = NetworkSession.shared
    }

    // MARK: - Public API

    public func chargersNear(center: LatLon, radiusKm: Double = 10.0) async throws -> [Charger] {
        let dLat = radiusKm / 111.0
        let dLon = radiusKm / (111.0 * max(cos(center.lat * .pi / 180.0), 0.2))
        let chargers = try await loadArea(
            minLat: center.lat - dLat, minLon: center.lon - dLon,
            maxLat: center.lat + dLat, maxLon: center.lon + dLon,
            // One circle covers a radius search directly — no tiling needed.
            googleCenters: [center]
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
            googleCenters: sampleAlongRoute(routePoints)
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

    // MARK: - Private

    private func loadArea(
        minLat: Double,
        minLon: Double,
        maxLat: Double,
        maxLon: Double,
        googleCenters: [LatLon]
    ) async throws -> [Charger] {
        let prefixes = Geohash.coveringPrefixes(minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon, precision: 4)
        let now = Date()

        let stale = prefixes.contains { prefix in
            let oldest = oldestCachedAt(prefix: prefix)
            return oldest == nil || now.timeIntervalSince(oldest!) > Self.cacheTTL
        }

        var refreshError: (any Error)?
        if stale {
            do {
                switch source() {
                case .openChargeMap:
                    try await refreshArea(minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon)
                case .googlePlaces:
                    try await refreshGooglePlaces(centers: googleCenters)
                case .appleMaps:
                    try await refreshAppleMaps(centers: googleCenters)
                case .combined:
                    try await refreshArea(minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon)
                    try await refreshAppleMaps(centers: googleCenters)
                }
                // Deduplicate combined results: Apple Maps duplicates close to OCM
                // entries are removed, keeping OCM's richer data.
                if source() == .combined {
                    try deduplicateCombined()
                }
            } catch {
                // Cached data is better than an error, so hold this and only throw
                // if the cache turns out to be empty too.
                refreshError = error
            }
        }

        var seen = Set<String>()
        var results: [Charger] = []
        for prefix in prefixes {
            let entities = try byGeohashPrefix(prefix)
            for entity in entities {
                guard !seen.contains(entity.id) else { continue }
                guard entity.lat >= minLat && entity.lat <= maxLat && entity.lon >= minLon && entity.lon <= maxLon else { continue }
                seen.insert(entity.id)
                results.append(entityToDomain(entity))
            }
        }
        // Without this the UI reports "no chargers here" when the truth is "the
        // charger database refused the request" — two very different problems.
        if results.isEmpty, let refreshError { throw refreshError }
        return results
    }

    private func oldestCachedAt(prefix: String) -> Date? {
        let descriptor = FetchDescriptor<ChargerEntity>(
            predicate: #Predicate { $0.geohash.starts(with: prefix) },
            sortBy: [SortDescriptor(\.cachedAt, order: .forward)]
        )
        return (try? modelContext.fetch(descriptor).first?.cachedAt) ?? nil
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

    /// Thins a route down to the circle centres worth querying.
    ///
    /// Tiles overlap slightly at this spacing so a charger sitting between two
    /// samples is still inside one of them. Long routes are decimated to the tile
    /// ceiling rather than refused — a sparse result beats a bill for 300 requests.
    private func sampleAlongRoute(_ points: [LatLon]) -> [LatLon] {
        guard let first = points.first else { return [] }
        let spacingKm = Self.googleTileRadiusM / 1000 * 1.6

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

    private func refreshGooglePlaces(centers: [LatLon]) async throws {
        let key = googleApiKey().trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else {
            _servingCachedData.value = true
            throw ChargerError.missingGoogleKey
        }
        guard !centers.isEmpty else { return }

        let now = Date()
        var inserted = 0
        var lastError: (any Error)?

        for center in centers.prefix(Self.googleMaxTiles) {
            do {
                inserted += try await fetchGoogleCircle(center: center, key: key, now: now)
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

    private func fetchGoogleCircle(center: LatLon, key: String, now: Date) async throws -> Int {
        var request = URLRequest(url: URL(string: "https://places.googleapis.com/v1/places:searchNearby")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "X-Goog-Api-Key")
        // The field mask decides the billing SKU. `evChargeOptions` is what makes
        // these places usable as chargers rather than pins on a map.
        request.setValue(
            "places.id,places.displayName,places.location,places.evChargeOptions,places.businessStatus",
            forHTTPHeaderField: "X-Goog-FieldMask"
        )
        request.httpBody = try encoder.encode(PlacesNearbyRequest(
            includedTypes: ["electric_vehicle_charging_station"],
            maxResultCount: Self.googleMaxResults,
            locationRestriction: .init(circle: .init(
                center: .init(latitude: center.lat, longitude: center.lon),
                radius: Self.googleTileRadiusM
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
        // A place with no recognised connector is a charging location Google knows
        // nothing useful about — routing can't reason about it, so drop it.
        guard !connectors.isEmpty else { return nil }

        let connectorsJson = (try? encoder.encode(connectors)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        return ChargerEntity(
            id: "gp-\(id)",
            name: place.displayName?.text ?? "Charger",
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

        return ChargerEntity(
            id: "ocm-\(id)",
            name: poi.AddressInfo?.Title ?? "Charger",
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
            usageCost: entity.usageCost
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
    /// persists results (name, location only — Apple's POI data has no pricing,
    /// connector type or operator information).
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
                let id = "apple-\(Geohash.encode(lat: lat, lon: lon, precision: 10))"
                // Skip if already cached (dedup across tiles and future refreshes)
                let existing = try modelContext.fetch(
                    FetchDescriptor<ChargerEntity>(
                        predicate: #Predicate { $0.id == id }
                    )
                )
                guard existing.isEmpty else { continue }
                let entity = ChargerEntity(
                    id: id,
                    name: name,
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
