import CoreDomain
import Foundation

/// A place the driver can pick as an endpoint or stopover.
public struct PlaceResult: Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let subtitle: String
    public let location: LatLon

    public init(id: String = UUID().uuidString, name: String, subtitle: String = "", location: LatLon) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.location = location
    }
}

/// Place search for the trip planner.
///
/// Uses whichever provider the user configured for routing, so one key covers both
/// — except that Google POI search is opt-in (`googlePoiSearch`), because Places
/// Text Search bills per request while Directions is far cheaper.
public final class GeocodingRepository: Sendable {

    private let session: URLSession
    private let preferences: PreferencesRepositoryImpl

    public init(preferences: PreferencesRepositoryImpl, session: URLSession = .shared) {
        self.preferences = preferences
        self.session = session
    }

    /// - Parameter near: biases results toward the driver rather than returning the
    ///   most globally famous match — searching "Shell" should not offer a station
    ///   on another continent.
    public func search(_ query: String, near: LatLon? = nil) async throws -> [PlaceResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }

        let prefs = preferences.currentPreferences
        let useGoogle = prefs.routingProvider == .googleMaps || prefs.googlePoiSearch

        if useGoogle, let key = prefs.googleMapsApiKey, !key.isEmpty {
            return try await googleSearch(trimmed, near: near, key: key)
        }
        if let key = prefs.orsApiKey, !key.isEmpty {
            return try await orsSearch(trimmed, near: near, key: key)
        }
        throw RoutingError.missingKey(prefs.routingProvider)
    }

    // MARK: - OpenRouteService (Pelias)

    private func orsSearch(_ query: String, near: LatLon?, key: String) async throws -> [PlaceResult] {
        var components = URLComponents(string: "https://api.openrouteservice.org/geocode/search")!
        var items: [URLQueryItem] = [
            // The Pelias-backed geocoder takes the key as a query parameter, unlike
            // directions, which authenticates via a header.
            .init(name: "api_key", value: key),
            .init(name: "text", value: query),
            .init(name: "size", value: "10")
        ]
        if let near {
            items.append(.init(name: "focus.point.lat", value: String(near.lat)))
            items.append(.init(name: "focus.point.lon", value: String(near.lon)))
        }
        components.queryItems = items

        let (data, _) = try await session.data(from: components.url!)
        let response = try JSONDecoder().decode(PeliasResponse.self, from: data)

        return response.features.compactMap { feature in
            guard feature.geometry.coordinates.count >= 2 else { return nil }
            let properties = feature.properties
            return PlaceResult(
                id: properties.gid ?? UUID().uuidString,
                name: properties.name ?? query,
                subtitle: [properties.locality, properties.region, properties.country]
                    .compactMap { $0 }.joined(separator: ", "),
                // GeoJSON is [lon, lat].
                location: LatLon(lat: feature.geometry.coordinates[1], lon: feature.geometry.coordinates[0])
            )
        }
    }

    // MARK: - Google Places

    private func googleSearch(_ query: String, near: LatLon?, key: String) async throws -> [PlaceResult] {
        var request = URLRequest(url: URL(string: "https://places.googleapis.com/v1/places:searchText")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "X-Goog-Api-Key")
        // The field mask is mandatory and determines what the call is billed at.
        request.setValue(
            "places.id,places.displayName,places.formattedAddress,places.location",
            forHTTPHeaderField: "X-Goog-FieldMask"
        )

        var body: [String: Any] = ["textQuery": query, "maxResultCount": 10]
        if let near {
            body["locationBias"] = [
                "circle": [
                    "center": ["latitude": near.lat, "longitude": near.lon],
                    "radius": 50_000
                ]
            ]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RoutingError.provider(
                "Google Places rejected the request (HTTP \(http.statusCode)). Enable \"Places API (New)\" on the key."
            )
        }

        let decoded = try JSONDecoder().decode(GooglePlacesResponse.self, from: data)
        return decoded.places.compactMap { place in
            guard let location = place.location else { return nil }
            return PlaceResult(
                id: place.id ?? UUID().uuidString,
                name: place.displayName?.text ?? query,
                subtitle: place.formattedAddress ?? "",
                location: LatLon(lat: location.latitude, lon: location.longitude)
            )
        }
    }
}

// MARK: - Wire format

private struct PeliasResponse: Decodable {
    struct Feature: Decodable {
        struct Geometry: Decodable { let coordinates: [Double] }
        struct Properties: Decodable {
            let gid: String?
            let name: String?
            let locality: String?
            let region: String?
            let country: String?
        }
        let geometry: Geometry
        let properties: Properties
    }
    let features: [Feature]

    private enum CodingKeys: String, CodingKey { case features }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        features = try container.decodeIfPresent([Feature].self, forKey: .features) ?? []
    }
}

private struct GooglePlacesResponse: Decodable {
    struct Place: Decodable {
        struct DisplayName: Decodable { let text: String? }
        struct Location: Decodable {
            let latitude: Double
            let longitude: Double
        }
        let id: String?
        let displayName: DisplayName?
        let formattedAddress: String?
        let location: Location?
    }
    let places: [Place]

    private enum CodingKeys: String, CodingKey { case places }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        places = try container.decodeIfPresent([Place].self, forKey: .places) ?? []
    }
}
