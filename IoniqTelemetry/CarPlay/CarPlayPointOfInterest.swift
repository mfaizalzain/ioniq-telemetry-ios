import CarPlay
import CoreDomain
import CoreLocation
import MapKit

/// Builds the charger entries for `CPPointOfInterestTemplate`.
///
/// Each POI carries a "Navigate" button that hands off to Maps — the charging
/// entitlement exists to let a driver find and reach a charger, and handing off is
/// the sanctioned way to do that without being a navigation app.
enum CarPlayPointOfInterest {

    static func make(from charger: Charger, origin: LatLon) -> CPPointOfInterest {
        let coordinate = CLLocationCoordinate2D(latitude: charger.lat, longitude: charger.lon)
        let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        mapItem.name = charger.name

        let poi = CPPointOfInterest(
            location: mapItem,
            title: charger.name,
            subtitle: subtitle(for: charger, origin: origin),
            summary: charger.operator,
            detailTitle: charger.name,
            detailSubtitle: subtitle(for: charger, origin: origin),
            detailSummary: charger.usageCost,
            pinImage: nil
        )
        // Capture the coordinate rather than the MKMapItem: the button handler is
        // @Sendable and MKMapItem is not, so the item is rebuilt on the main actor.
        // Apple Maps only here — the chargers are drawn on a MapKit template, and
        // handing off to Google Maps sends the driver to the phone screen mid-drive.
        let destination = LatLon(lat: charger.lat, lon: charger.lon)
        let name = charger.name
        poi.primaryButton = CPTextButton(
            title: "Navigate",
            textStyle: .confirm
        ) { _ in
            Task { @MainActor in
                MapsNavigation.navigate(to: destination, name: name, preferGoogleMaps: false)
            }
        }
        return poi
    }

    private static func subtitle(for charger: Charger, origin: LatLon) -> String {
        var parts: [String] = []
        if charger.maxPowerKw > 0 {
            parts.append(String(format: "%.0f kW", charger.maxPowerKw))
        }
        parts.append(String(format: "%.1f km", distanceKm(origin, charger)))
        if let price = charger.pricePerKwh {
            parts.append(String(format: "%.2f/kWh", price))
        }
        if !charger.isOperational {
            parts.append("Out of service")
        }
        return parts.joined(separator: " · ")
    }

    private static func distanceKm(_ origin: LatLon, _ charger: Charger) -> Double {
        CLLocation(latitude: origin.lat, longitude: origin.lon)
            .distance(from: CLLocation(latitude: charger.lat, longitude: charger.lon)) / 1000
    }
}

/// One-shot location for the CarPlay scene, which has no SwiftUI environment to
/// borrow a provider from.
@MainActor
final class CarPlayLocation: NSObject, CLLocationManagerDelegate {
    static let shared = CarPlayLocation()

    private let manager = CLLocationManager()
    private var continuations: [CheckedContinuation<LatLon?, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func currentLocation() async -> LatLon? {
        if let location = manager.location {
            return LatLon(lat: location.coordinate.latitude, lon: location.coordinate.longitude)
        }
        // CarPlay must not be the surface that first asks for permission — there is
        // no good way to answer a prompt while driving. If it isn't already granted,
        // the charger tab simply stays empty until the phone app has asked.
        guard manager.authorizationStatus == .authorizedAlways
            || manager.authorizationStatus == .authorizedWhenInUse else { return nil }

        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
            manager.requestLocation()
        }
    }

    private func resume(_ value: LatLon?) {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume(returning: value) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let value = locations.last.map { LatLon(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude) }
        Task { @MainActor in self.resume(value) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.resume(nil) }
    }
}
