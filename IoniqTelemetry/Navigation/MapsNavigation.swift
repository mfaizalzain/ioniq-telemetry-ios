import CoreDomain
import CoreLocation
@preconcurrency import MapKit
import UIKit

/// Hand-off to a navigation app.
///
/// The app plans charge stops but does not navigate — it has no CarPlay navigation
/// entitlement and no business drawing turn-by-turn. Google Maps is preferred when
/// installed and the user selected it, since a driver who chose it there expects it
/// here too.
enum MapsNavigation {

    /// Opens the destination in Apple Maps with driving directions.
    @MainActor
    static func navigate(to mapItem: MKMapItem) {
        mapItem.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
        ])
    }

    /// - Parameter preferGoogleMaps: on by default — Google Maps whenever it is
    ///   installed, Apple Maps only as the fallback. Pass `false` to force Apple Maps.
    @MainActor
    static func navigate(to location: LatLon, name: String? = nil, preferGoogleMaps: Bool = true) {
        if preferGoogleMaps, let url = googleMapsURL(for: location), canOpenGoogleMaps {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            return
        }
        let mapItem = MKMapItem(placemark: MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: location.lat, longitude: location.lon)
        ))
        mapItem.name = name
        navigate(to: mapItem)
    }

    /// Geocodes a free-text destination, then hands off. Falls back to opening a
    /// Maps search rather than failing silently when nothing matches.
    @MainActor
    static func navigate(toAddress address: String, preferGoogleMaps: Bool = true) async {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = address
        let response = try? await MKLocalSearch(request: request).start()
        guard let item = response?.mapItems.first else {
            let encoded = address.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let url = URL(string: "http://maps.apple.com/?q=\(encoded)") {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
            return
        }
        navigate(
            to: LatLon(lat: item.placemark.coordinate.latitude, lon: item.placemark.coordinate.longitude),
            name: item.name,
            preferGoogleMaps: preferGoogleMaps
        )
    }

    @MainActor
    static var canOpenGoogleMaps: Bool {
        guard let url = URL(string: "comgooglemaps://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    private static func googleMapsURL(for location: LatLon) -> URL? {
        URL(string: "comgooglemaps://?daddr=\(location.lat),\(location.lon)&directionsmode=driving")
    }

    // MARK: - Whole trip

    /// Navigates the whole plan: origin, every stopover and charge stop in route
    /// order, then the destination. Ported from Android `tripDirectionsIntent`.
    ///
    /// Google Maps whenever it is installed, since it is the only one of the two
    /// that can take intermediate stops. Without it the trip falls back to Apple
    /// Maps, which accepts a single destination only — so the stops are lost, and
    /// that is still better than dropping the driver into a browser.
    @MainActor
    static func navigateTrip(_ plan: TripPlan) {
        let intermediate = (
            plan.userWaypoints.map { ($0.distanceFromOriginKm, $0.location) } +
            plan.stops.map { ($0.distanceFromOriginKm, LatLon(lat: $0.charger.lat, lon: $0.charger.lon)) }
        )
        .sorted { $0.0 < $1.0 }
        .map { "\($0.1.lat),\($0.1.lon)" }

        guard !intermediate.isEmpty, canOpenGoogleMaps else {
            navigate(to: plan.destination)
            return
        }

        var components = URLComponents(string: "https://www.google.com/maps/dir/")!
        components.queryItems = [
            .init(name: "api", value: "1"),
            .init(name: "origin", value: "\(plan.origin.lat),\(plan.origin.lon)"),
            .init(name: "destination", value: "\(plan.destination.lat),\(plan.destination.lon)"),
            .init(name: "travelmode", value: "driving"),
            .init(name: "waypoints", value: intermediate.joined(separator: "|"))
        ]

        if let url = components.url {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        } else {
            navigate(to: plan.destination)
        }
    }
}
