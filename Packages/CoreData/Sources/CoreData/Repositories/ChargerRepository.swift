import Combine
import CoreDomain
import Foundation
import SwiftData

/// Repository for charger data — OCM API fetch + local cache with 7-day TTL.
public final class ChargerRepository: @unchecked Sendable {
    private let modelContext: ModelContext
    /// Read per request, not captured at init: the user can paste a key into
    /// Settings at any time and the next lookup must pick it up.
    private let apiKey: @Sendable () -> String
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

    public init(modelContext: ModelContext, apiKey: @escaping @Sendable () -> String) {
        self.modelContext = modelContext
        self.apiKey = apiKey
        self.session = URLSession.shared
    }

    // MARK: - Public API

    public func chargersNear(center: LatLon, radiusKm: Double = 10.0) async throws -> [Charger] {
        let dLat = radiusKm / 111.0
        let dLon = radiusKm / (111.0 * max(cos(center.lat * .pi / 180.0), 0.2))
        let chargers = try await loadArea(
            minLat: center.lat - dLat, minLon: center.lon - dLon,
            maxLat: center.lat + dLat, maxLon: center.lon + dLon
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

        let chargers = try await loadArea(minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon)
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

    private func loadArea(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double) async throws -> [Charger] {
        let prefixes = Geohash.coveringPrefixes(minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon, precision: 4)
        let now = Date()

        let stale = prefixes.contains { prefix in
            let oldest = oldestCachedAt(prefix: prefix)
            return oldest == nil || now.timeIntervalSince(oldest!) > Self.cacheTTL
        }

        var refreshError: (any Error)?
        if stale {
            do {
                try await refreshArea(minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon)
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
            let (data, response) = try await session.data(from: url)
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

    // MARK: - Errors

public enum ChargerError: LocalizedError {
    case missingApiKey
    case badRequest
    case httpStatus(Int)
    case transport(any Error)

    public var errorDescription: String? {
        switch self {
        case .missingApiKey:
            return "Add an Open Charge Map key in Settings to look up chargers."
        case .badRequest:
            return "Could not build the charger request."
        case .httpStatus(let code) where code == 401 || code == 403:
            return "Open Charge Map rejected the key. Check it in Settings."
        case .httpStatus(let code):
            return "Charger database returned an error (HTTP \(code))."
        case .transport(let error):
            return "Could not reach the charger database: \(error.localizedDescription)"
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
