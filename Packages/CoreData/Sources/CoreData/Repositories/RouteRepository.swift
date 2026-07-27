import CoreDomain
import Foundation

/// A routed path between points, before charging stops are placed on it.
public struct BaseRoute: Sendable, Equatable {
    public let points: [LatLon]
    public let distanceKm: Float
    public let driveMinutes: Int

    /// Cumulative climb and drop — the sum of every uphill and downhill stretch, not
    /// the net change between endpoints. Only OpenRouteService reports these.
    public let ascendM: Float
    public let descendM: Float
    public let encodedPolyline: String

    /// Whether the provider reported elevation at all. Without this a Google route
    /// (always 0/0) is indistinguishable from a genuinely flat ORS one, so the UI
    /// cannot tell the driver which they are looking at.
    public let hasElevationData: Bool

    /// Net change from origin to destination; negative for a net descent.
    ///
    /// The physics model applies one uniform grade across a segment, so it needs the
    /// net figure — feeding it cumulative ascent would charge the driver for every
    /// climb and credit them for none of the descents.
    public var netAscendM: Float { ascendM - descendM }

    /// Elevation to hand the solver; nil when the provider reports none.
    public var elevation: RouteElevation? {
        hasElevationData ? RouteElevation(ascendM: ascendM, descendM: descendM) : nil
    }
}

/// Routing is bring-your-own-key: the app ships no key of its own, so each user's
/// requests land on their own free tier rather than a shared app-wide quota.
public enum RoutingError: LocalizedError {
    case missingKey(RoutingProvider)
    case noRoute
    case provider(String)

    public var errorDescription: String? {
        switch self {
        case .missingKey(let provider):
            let name = provider == .openRouteService ? "OpenRouteService" : "Google Maps"
            return "Add a \(name) key in Settings to plan a route."
        case .noRoute:
            return "No drivable route between those points."
        case .provider(let message):
            return message
        }
    }
}

/// Routes through the user's selected provider.
///
/// There is deliberately no fallback between providers: both are keyed to the user,
/// so a failure means their key or quota needs attention, and silently rerouting
/// through the other engine would only hide that.
public final class RouteRepository: Sendable {

    private let session: URLSession
    private let preferences: PreferencesRepositoryImpl

    public init(preferences: PreferencesRepositoryImpl, session: URLSession = .shared) {
        self.preferences = preferences
        self.session = session
    }

    public func route(origin: LatLon, destination: LatLon) async throws -> BaseRoute {
        try await route(points: [origin, destination])
    }

    public func route(points: [LatLon]) async throws -> BaseRoute {
        guard points.count >= 2 else { throw RoutingError.noRoute }

        let prefs = preferences.currentPreferences
        let provider = prefs.routingProvider
        let key: String? = provider == .openRouteService ? prefs.orsApiKey : prefs.googleMapsApiKey
        guard let key, !key.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw RoutingError.missingKey(provider)
        }

        switch provider {
        case .openRouteService: return try await orsRoute(points: points, key: key)
        case .googleMaps: return try await googleRoute(points: points, key: key)
        }
    }

    // MARK: - OpenRouteService

    private func orsRoute(points: [LatLon], key: String) async throws -> BaseRoute {
        var request = URLRequest(url: URL(string: "https://api.openrouteservice.org/v2/directions/driving-car")!)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // ORS takes lon,lat — the reverse of every other engine here.
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "coordinates": points.map { [$0.lon, $0.lat] },
            "elevation": true,
            "instructions": false
        ])

        let (data, _) = try await session.data(for: request)
        let response = try JSONDecoder().decode(OrsDirectionsResponse.self, from: data)

        if let error = response.error {
            throw RoutingError.provider("OpenRouteService: \(error.message ?? "error \(error.code ?? -1)")")
        }
        guard let route = response.routes?.first else { throw RoutingError.noRoute }

        let encoded = route.geometry ?? ""
        return BaseRoute(
            // elevation=true makes this a 3D polyline; the decoder skips the third delta.
            points: encoded.isEmpty ? [] : Polyline.decode(encoded, is3D: true),
            distanceKm: Float((route.summary?.distance ?? 0) / 1000),
            driveMinutes: Int((route.summary?.duration ?? 0) / 60),
            ascendM: Float(route.summary?.ascent ?? 0),
            descendM: Float(route.summary?.descent ?? 0),
            encodedPolyline: encoded,
            hasElevationData: route.summary?.ascent != nil || route.summary?.descent != nil
        )
    }

    // MARK: - Google Maps

    private func googleRoute(points: [LatLon], key: String) async throws -> BaseRoute {
        var components = URLComponents(string: "https://maps.googleapis.com/maps/api/directions/json")!
        var items: [URLQueryItem] = [
            .init(name: "origin", value: "\(points.first!.lat),\(points.first!.lon)"),
            .init(name: "destination", value: "\(points.last!.lat),\(points.last!.lon)"),
            .init(name: "key", value: key)
        ]
        let intermediate = points.dropFirst().dropLast()
        if !intermediate.isEmpty {
            items.append(.init(name: "waypoints", value: intermediate.map { "\($0.lat),\($0.lon)" }.joined(separator: "|")))
        }
        components.queryItems = items

        let (data, _) = try await session.data(from: components.url!)
        let response = try JSONDecoder().decode(GoogleDirectionsResponse.self, from: data)

        guard response.status == "OK" else {
            throw RoutingError.provider(Self.googleMessage(response.status, response.error_message))
        }
        guard let route = response.routes?.first else { throw RoutingError.noRoute }

        let legs = route.legs ?? []
        let encoded = route.overview_polyline?.points ?? ""
        return BaseRoute(
            // Google overview polylines are precision-5 and carry no elevation.
            points: encoded.isEmpty ? [] : Polyline.decode(encoded, is3D: false),
            distanceKm: Float(legs.compactMap { $0.distance?.value }.reduce(0, +)) / 1000,
            driveMinutes: Int(legs.compactMap { $0.duration?.value }.reduce(0, +) / 60),
            ascendM: 0,
            descendM: 0,
            encodedPolyline: encoded,
            hasElevationData: false
        )
    }

    /// Turns a Google Directions status into something the driver can act on.
    static func googleMessage(_ status: String?, _ detail: String?) -> String {
        switch status {
        case "REQUEST_DENIED":
            return "Google Maps rejected your API key — enable the Directions API and set the key's Application restriction to None (an \"Android apps\" restriction blocks web-service calls)."
        case "OVER_QUERY_LIMIT", "OVER_DAILY_LIMIT":
            return "Your Google Maps quota is exhausted, or billing isn't enabled on the key."
        case "ZERO_RESULTS":
            return "Google Maps found no drivable route between these points."
        case "INVALID_REQUEST":
            return "Google Maps rejected the request as invalid."
        default:
            let suffix = detail.map { " (\($0))" } ?? ""
            return "Google Maps error: \(status ?? "unknown")\(suffix)"
        }
    }
}

// MARK: - Wire format

private struct OrsDirectionsResponse: Decodable {
    struct Route: Decodable {
        struct Summary: Decodable {
            let distance: Double?
            let duration: Double?
            let ascent: Double?
            let descent: Double?
        }
        let geometry: String?
        let summary: Summary?
    }
    struct ApiError: Decodable {
        let code: Int?
        let message: String?
    }
    let routes: [Route]?
    let error: ApiError?
}

private struct GoogleDirectionsResponse: Decodable {
    struct Route: Decodable {
        struct Leg: Decodable {
            struct Value: Decodable { let value: Double? }
            let distance: Value?
            let duration: Value?
        }
        struct Overview: Decodable { let points: String? }
        let legs: [Leg]?
        let overview_polyline: Overview?
    }
    let routes: [Route]?
    let status: String?
    let error_message: String?
}
