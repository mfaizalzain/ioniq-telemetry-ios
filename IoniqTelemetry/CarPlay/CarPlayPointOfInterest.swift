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

    /// Live occupancy of a charger's matched station, or nil when the charger
    /// has no live status. Only real reported data — never an inference from
    /// other stations in the area.
    struct ChargerLiveStatus: Equatable {
        let available: Int
        let total: Int

        var isFull: Bool { available <= 0 }

        var label: String {
            isFull ? "Full — no connectors free" : "\(available) of \(total) connectors free"
        }
    }

    static func make(
        from candidate: ChargerCandidate,
        origin: LatLon,
        liveStatus: ChargerLiveStatus? = nil,
        liveConsumption: Float? = nil,
        onSetDestination: (@MainActor (Charger) -> Void)? = nil
    ) -> CPPointOfInterest {
        let charger = candidate.charger
        let coordinate = CLLocationCoordinate2D(latitude: charger.lat, longitude: charger.lon)
        let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        mapItem.name = charger.name
        let detail = subtitle(
            for: candidate,
            origin: origin,
            liveStatus: liveStatus,
            liveConsumption: liveConsumption
        )

        let poi = CPPointOfInterest(
            location: mapItem,
            title: charger.name,
            subtitle: detail,
            summary: charger.operator,
            detailTitle: charger.name,
            detailSubtitle: detail,
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
        if let onSetDestination {
            let destinationCharger = charger
            poi.secondaryButton = CPTextButton(
                title: "Set as destination",
                textStyle: .normal
            ) { _ in
                Task { @MainActor in
                    onSetDestination(destinationCharger)
                }
            }
        }
        return poi
    }

    private static func subtitle(
        for candidate: ChargerCandidate,
        origin: LatLon,
        liveStatus: ChargerLiveStatus? = nil,
        liveConsumption: Float? = nil
    ) -> String {
        let charger = candidate.charger
        var parts: [String] = []
        if charger.maxPowerKw > 0 {
            let ultra = candidate.isUltraFast ? " ⚡" : ""
            parts.append(String(format: "%.0f kW%@", charger.maxPowerKw, ultra))
        }
        parts.append(String(format: "%.1f km", distanceKm(origin, charger)))
        if let liveConsumption {
            parts.append(String(format: "%.1f kWh/100 km now", liveConsumption))
        }
        if let arrival = candidate.arrivalSoc {
            switch candidate.reach {
            case .comfortable:
                parts.append("arrive ~\(Int(arrival))%")
            case .tight:
                parts.append("tight ~\(Int(arrival))%")
            case .outOfRange:
                parts.append("out of range")
            case .unknown:
                parts.append("arrive ~\(Int(arrival))%")
            }
        } else {
            parts.append("plug OBD for range")
        }
        if !charger.isOperational {
            parts.append("Out of service")
        }
        if let liveStatus {
            parts.append(liveStatus.label)
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
        // A cached fix is only usable while it's recent — the same rule as the
        // phone's LocationProvider. CLLocationManager.location can be hours old
        // or from a different place, which would center the charger list in the
        // wrong town.
        if let location = manager.location, LocationProvider.isFreshEnough(location) {
            return LatLon(lat: location.coordinate.latitude, lon: location.coordinate.longitude)
        }
        // CarPlay must not be the surface that first asks for permission — there is
        // no good way to answer a prompt while driving. An ungranted permission is
        // therefore a missing location, not permission to use an arbitrary cached
        // position from another drive.
        guard manager.authorizationStatus == .authorizedAlways
            || manager.authorizationStatus == .authorizedWhenInUse else {
            return nil
        }

        let fresh = await withCheckedContinuation { continuation in
            continuations.append(continuation)
            manager.requestLocation()
        }
        return fresh
    }

    /// The latest fresh fix, synchronously — for surfaces that render on a
    /// timer and must not await a location request mid-frame.
    var freshFix: LatLon? {
        guard let location = manager.location, LocationProvider.isFreshEnough(location) else { return nil }
        return LatLon(lat: location.coordinate.latitude, lon: location.coordinate.longitude)
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
