import Combine
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
        /// Google Places resource id ("places/…"). Present because the request
        /// asks for it; used for exact identity matching against chargers that
        /// were themselves sourced from Places.
        public let placeId: String?
        /// Station coordinates; the proximity guard that pins a station to the
        /// charger at its physical site. Nil when Places omitted the location.
        public let lat: Double?
        public let lon: Double?

        /// Zero free connectors is occupied, whether or not Places also told us how
        /// many connectors the station has. Requiring `totalCount > 0` meant a
        /// station that reported "0 available" but omitted `connectorCount` counted
        /// as *not* occupied and suppressed the alert for the whole stop — the
        /// opposite of the documented rule, and out of step with Android's
        /// `available <= 0`.
        public var isOccupied: Bool { availableCount <= 0 }

        public init(
            name: String,
            availableCount: Int,
            totalCount: Int,
            placeId: String? = nil,
            lat: Double? = nil,
            lon: Double? = nil
        ) {
            self.name = name
            self.availableCount = availableCount
            self.totalCount = totalCount
            self.placeId = placeId
            self.lat = lat
            self.lon = lon
        }
    }

    /// Only stations that actually reported availability.
    public let stations: [Station]

    /// Whether any station reported live status at all.
    public var hasStatus: Bool { !stations.isEmpty }

    /// True when every station reporting status has zero free connectors.
    public var allOccupied: Bool { hasStatus && stations.allSatisfy(\.isOccupied) }
}

/// Counts billed Google Places requests for the current app run.
///
/// Places bills per call against the user's own key, and nothing in the app made
/// that visible — the first sign of a runaway poll was the Cloud console bill. Not
/// persisted: it answers "what is this session costing me", and a lifetime total
/// would need reconciling with Google's own metering to mean anything.
public final class PlacesUsageCounter: @unchecked Sendable {
    public static let shared = PlacesUsageCounter()

    private let lock = NSLock()
    private let subject = CurrentValueSubject<Int, Never>(0)

    public var count: AnyPublisher<Int, Never> { subject.eraseToAnyPublisher() }
    public var currentCount: Int { subject.value }

    public func record(_ requests: Int = 1) {
        lock.withLock { subject.value += requests }
    }

    public func reset() {
        lock.withLock { subject.value = 0 }
    }
}

public final class OccupancyRepository: Sendable {

    private let session: URLSession
    private static let endpoint = URL(string: "https://places.googleapis.com/v1/places:searchNearby")!

    public init(session: URLSession = NetworkSession.shared) {
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
            "places.id,places.displayName,places.location,places.evChargeOptions",
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

        let (data, response) = try await session.dataWithRetry(for: request)
        // Recorded on a response, not before the call: this counter exists to mirror
        // what Google bills, and a request that never reached them — no signal, DNS
        // failure — is not a billed call. A non-2xx that did reach them still is.
        PlacesUsageCounter.shared.record()

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
                totalCount: options.connectorCount ?? 0,
                placeId: place.id,
                lat: place.location?.latitude,
                lon: place.location?.longitude
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
        struct Location: Decodable {
            let latitude: Double?
            let longitude: Double?
        }
        struct EvChargeOptions: Decodable {
            struct ConnectorAggregation: Decodable {
                let availableCount: Int?
                let count: Int?
            }
            let connectorCount: Int?
            let connectorAggregation: [ConnectorAggregation]?
        }
        let id: String?
        let displayName: DisplayName?
        let location: Location?
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
