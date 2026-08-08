import CoreDomain
import Foundation

/// Pins a charger to the statused station at its physical site.
///
/// Two tiers, strongest first:
///  - Exact identity: a charger row sourced from Google Places (id "gp-…")
///    carries the same Places resource id as its station, so the match is exact
///    and cannot be wrong. Identity beats coordinates and names, which both
///    drift between sources.
///  - Proximity: everything else (OCM rows) matches the nearest statused station
///    at the same physical site. If two stations are nearly equidistant, the site
///    is ambiguous and the charger gets no status rather than a possibly wrong one.
public enum ChargerStationMatching {
    /// A charger and its station are the same site only within this radius.
    /// 1 km is deliberately loose enough to absorb OCM coordinate drift (pins are
    /// often dropped at a site's entrance or car park), while still far too tight
    /// for a same-named station in another town to claim a charger.
    public static let matchRadiusM = 1_000.0
    /// Two stations closer than this in distance-from-charger are ambiguous.
    public static let ambiguousMarginM = 40.0

    public static func match(
        _ charger: Charger,
        stations: [OccupancySnapshot.Station]
    ) -> OccupancySnapshot.Station? {
        if charger.id.hasPrefix("gp-") {
            let placesId = String(charger.id.dropFirst(3))
            if let exact = stations.first(where: { $0.placeId == placesId }) {
                return exact
            }
        }

        let nearby = stations.compactMap { station -> (OccupancySnapshot.Station, Double)? in
            guard let lat = station.lat, let lon = station.lon else { return nil }
            let dist = distanceMeters(charger.lat, charger.lon, lat, lon)
            guard dist <= matchRadiusM else { return nil }
            return (station, dist)
        }
        let ranked = nearby.sorted { $0.1 < $1.1 }

        switch ranked.count {
        case 0:
            return nil
        case 1:
            return ranked[0].0
        default:
            guard ranked[1].1 - ranked[0].1 >= ambiguousMarginM else { return nil }
            return ranked[0].0
        }
    }

    /// Equirectangular distance in meters (fine at charger-site scale).
    static func distanceMeters(_ aLat: Double, _ aLon: Double, _ bLat: Double, _ bLon: Double) -> Double {
        let dLat = (bLat - aLat) * 111_000.0
        let dLon = (bLon - aLon) * 111_000.0 * cos((aLat + bLat) / 2 * .pi / 180)
        return (dLat * dLat + dLon * dLon).squareRoot()
    }
}
