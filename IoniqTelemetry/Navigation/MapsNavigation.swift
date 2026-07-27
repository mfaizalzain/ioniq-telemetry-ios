import CoreDomain
import CoreLocation
import MapKit
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

    @MainActor
    static func navigate(to location: LatLon, name: String? = nil, preferGoogleMaps: Bool = false) {
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
    static func navigate(toAddress address: String, preferGoogleMaps: Bool = false) async {
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
}
