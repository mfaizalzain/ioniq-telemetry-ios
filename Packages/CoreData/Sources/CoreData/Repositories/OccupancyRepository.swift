import CoreDomain
import Foundation

/// Live charger availability from the Google Places API (New).
///
/// Places is the only source that reports connector-level availability, and it
/// bills per request against the user's own key — so this is Pro- and key-gated by
/// the caller and polled sparingly by `OccupancyAlertMonitor`.
///
/// Stations that report no `evChargeOptions` are excluded rather than assumed
/// free: "no data" and "available" are different answers, and conflating them
/// would produce confident alerts built on nothing.
public struct OccupancySnapshot: Sendable, Equatable {
    public struct Station: Sendable, Equatable {
        public let name: String
        public let availableCount: Int
        public let totalCount: Int

        public var isOccupied: Bool { availableCount == 0 && totalCount > 0 }
    }

    /// Only stations that actually reported availability.
    public let stations: [Station]

    /// Whether any station reported live status at all.
    public var hasStatus: Bool { !stations.isEmpty }

    /// True when every station reporting status has zero free connectors.
    public var allOccupied: Bool { hasStatus && stations.allSatisfy(\.isOccupied) }
}

public final class OccupancyRepository: Sendable {

    private let session: URLSession
    private static let endpoint = URL(string: "https://places.googleapis.com/v1/places:searchNearby")!

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func occupancyNear(
        _ center: LatLon,
        radiusM: Double,
        apiKey: String
    ) async throws -> OccupancySnapshot {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        // Field mask is mandatory and is what the call is billed on — request only
        // the availability fields, not full place details.
        request.setValue(
            "places.displayName,places.evChargeOptions",
            forHTTPHeaderField: "X-Goog-FieldMask"
        )
        request.httpBody = try JSONEncoder().encode(NearbyRequest(
            includedTypes: ["electric_vehicle_charging_station"],
            maxResultCount: 10,
            locationRestriction: .init(circle: .init(
                center: .init(latitude: center.lat, longitude: center.lon),
                radius: radiusM
            ))
        ))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OccupancyError.requestFailed(
                (response as? HTTPURLResponse)?.statusCode ?? -1
            )
        }

        let decoded = try JSONDecoder().decode(NearbyResponse.self, from: data)
        let stations: [OccupancySnapshot.Station] = decoded.places.compactMap { place in
            guard let options = place.evChargeOptions else { return nil }
            let available = options.connectorAggregation?
                .compactMap(\.availableCount)
                .reduce(0, +)
            // No availableCount anywhere means this station reports no live status.
            guard let available else { return nil }
            return OccupancySnapshot.Station(
                name: place.displayName?.text ?? "Charger",
                availableCount: available,
                totalCount: options.connectorCount ?? 0
            )
        }
        return OccupancySnapshot(stations: stations)
    }
}

public enum OccupancyError: LocalizedError {
    case requestFailed(Int)

    public var errorDescription: String? {
        switch self {
        case .requestFailed(let status):
            return "Live availability lookup failed (HTTP \(status))."
        }
    }
}

// MARK: - Wire format

private struct NearbyRequest: Encodable {
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

private struct NearbyResponse: Decodable {
    struct Place: Decodable {
        struct DisplayName: Decodable { let text: String? }
        struct EvChargeOptions: Decodable {
            struct ConnectorAggregation: Decodable {
                let availableCount: Int?
                let count: Int?
            }
            let connectorCount: Int?
            let connectorAggregation: [ConnectorAggregation]?
        }
        let displayName: DisplayName?
        let evChargeOptions: EvChargeOptions?
    }

    let places: [Place]

    private enum CodingKeys: String, CodingKey { case places }

    // Places omits the array entirely when nothing matches.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        places = try container.decodeIfPresent([Place].self, forKey: .places) ?? []
    }
}
