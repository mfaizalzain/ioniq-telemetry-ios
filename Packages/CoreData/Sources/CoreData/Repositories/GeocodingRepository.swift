import CoreDomain
import Foundation
import MapKit

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
/// Apple Maps is the free default — no key needed. Falls back to ORS or Google
/// only when the user explicitly configured those providers.
public final class GeocodingRepository: Sendable {

    private let session: URLSession
    private let preferences: PreferencesRepositoryImpl

    public init(preferences: PreferencesRepositoryImpl, session: URLSession = NetworkSession.shared) {
        self.preferences = preferences
        self.session = session
    }

    /// - Parameter near: biases results toward the driver rather than returning the
    ///   most globally famous match — searching "Shell" should not offer a station
    ///   on another continent.
    public func search(_ query: String, near: LatLon? = nil) async throws -> [PlaceResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }

        if let coordinate = Self.parseCoordinate(trimmed) {
            return [PlaceResult(
                name: String(format: "%.5f, %.5f", coordinate.lat, coordinate.lon),
                subtitle: "Coordinates",
                location: coordinate
            )]
        }

        let prefs = preferences.currentPreferences
        let useGoogle = prefs.routingProvider == .googleMaps || prefs.googlePoiSearch

        if useGoogle, let key = prefs.googleMapsApiKey, !key.isEmpty {
            return try await googleSearch(trimmed, near: near, key: key)
        }
        if let key = prefs.orsApiKey, !key.isEmpty, prefs.routingProvider == .openRouteService {
            return try await orsSearch(trimmed, near: near, key: key)
        }
        return try await appleMapsSearch(trimmed, near: near)
    }

    // MARK: - Coordinates

    static func parseCoordinate(_ text: String) -> LatLon? {
        let cleaned = text
            .replacingOccurrences(of: "°", with: " ")
            .replacingOccurrences(of: ",", with: " ")
        let parts = cleaned
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        guard parts.count == 2 else { return nil }

        guard let first = component(parts[0], negative: ["s", "S"], positive: ["n", "N"]),
              let second = component(parts[1], negative: ["w", "W"], positive: ["e", "E"])
        else { return nil }

        guard (-90...90).contains(first), (-180...180).contains(second) else { return nil }
        return LatLon(lat: first, lon: second)
    }

    private static func component(_ raw: String, negative: [String], positive: [String]) -> Double? {
        var body = raw
        var hemisphereIsNegative = false

        for letter in negative + positive where body.hasPrefix(letter) || body.hasSuffix(letter) {
            body = body.replacingOccurrences(of: letter, with: "")
            hemisphereIsNegative = negative.contains(letter)
            break
        }

        guard let value = Double(body) else { return nil }
        return hemisphereIsNegative ? -abs(value) : value
    }

    // MARK: - OpenRouteService (Pelias)

    private func orsSearch(_ query: String, near: LatLon?, key: String) async throws -> [PlaceResult] {
        var components = URLComponents(string: "https://api.openrouteservice.org/geocode/search")!
        var items: [URLQueryItem] = [
            .init(name: "api_key", value: key),
            .init(name: "text", value: query),
            .init(name: "size", value: "10")
        ]
        if let near {
            items.append(.init(name: "focus.point.lat", value: String(near.lat)))
            items.append(.init(name: "focus.point.lon", value: String(near.lon)))
        }
        components.queryItems = items

        let (data, _) = try await session.dataWithRetry(from: components.url!)
        let response = try JSONDecoder().decode(PeliasResponse.self, from: data)

        return response.features.compactMap { feature in
            guard feature.geometry.coordinates.count >= 2 else { return nil }
            let properties = feature.properties
            return PlaceResult(
                id: properties.gid ?? UUID().uuidString,
                name: properties.name ?? query,
                subtitle: [properties.locality, properties.region, properties.country]
                    .compactMap { $0 }.joined(separator: ", "),
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

        PlacesUsageCounter.shared.record()
        let (data, response) = try await session.dataWithRetry(for: request)
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

    // MARK: - Apple Maps

    private func appleMapsSearch(_ query: String, near: LatLon?) async throws -> [PlaceResult] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest, .address]
        if let near {
            request.region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: near.lat, longitude: near.lon),
                latitudinalMeters: 50_000,
                longitudinalMeters: 50_000
            )
        }
        let search = MKLocalSearch(request: request)
        let response = try await search.start()
        return response.mapItems.map { item in
            let loc = item.placemark.location?.coordinate
            return PlaceResult(
                id: UUID().uuidString,
                name: item.name ?? query,
                subtitle: [
                    item.placemark.locality,
                    item.placemark.administrativeArea,
                    item.placemark.country
                ].compactMap { $0 }.joined(separator: ", "),
                location: LatLon(lat: loc?.latitude ?? 0, lon: loc?.longitude ?? 0)
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
