import CoreDomain
import Foundation
import Testing
@testable import CoreData

@Suite("ChargerStationMatching")
struct ChargerStationMatchingTests {

    private func station(
        name: String,
        lat: Double,
        lon: Double,
        available: Int = 1,
        total: Int = 2,
        placeId: String? = nil
    ) -> OccupancySnapshot.Station {
        OccupancySnapshot.Station(
            name: name,
            availableCount: available,
            totalCount: total,
            placeId: placeId,
            lat: lat,
            lon: lon
        )
    }

    private func charger(id: String, name: String, lat: Double, lon: Double) -> Charger {
        Charger(id: id, name: name, lat: lat, lon: lon)
    }

    @Test("charger far from a statused station does not inherit its occupancy")
    func farChargerHasNoStatus() {
        let stations = [
            station(name: "Petronas Charging Station", lat: 3.0, lon: 101.0, available: 1, total: 2)
        ]
        // Same shared word "station", but ~1.5 km away — the old name-only
        // matcher over a 25 km radius bound this one to Petronas's occupancy.
        let far = charger(id: "ocm-2", name: "Shell Recharge Station", lat: 3.01, lon: 101.01)

        #expect(ChargerStationMatching.match(far, stations: stations) == nil)
    }

    @Test("chargers at their own sites get distinct occupancy")
    func distinctSitesDistinctStatus() {
        let stations = [
            station(name: "Shell Recharge", lat: 3.0, lon: 101.0, available: 0, total: 2),
            station(name: "Petronas Charging Station", lat: 3.02, lon: 101.02, available: 2, total: 4)
        ]
        let shell = charger(id: "ocm-1", name: "Shell Recharge", lat: 3.0, lon: 101.0)
        let petronas = charger(id: "ocm-2", name: "Petronas Charging Station", lat: 3.02, lon: 101.02)

        #expect(ChargerStationMatching.match(shell, stations: stations)?.availableCount == 0)
        #expect(ChargerStationMatching.match(petronas, stations: stations)?.availableCount == 2)
    }

    @Test("google places charger matches its station by exact id even when names differ")
    func exactIdBeatsNames() {
        let stations = [
            station(
                name: "Petronas Charging Station",
                lat: 3.0,
                lon: 101.0,
                available: 1,
                total: 2,
                placeId: "places/ChIJabc"
            )
        ]
        // Names share no words at all; identity alone must carry the match.
        let placesCharger = charger(id: "gp-places/ChIJabc", name: "Gentari DC Fast", lat: 3.0, lon: 101.0)

        #expect(ChargerStationMatching.match(placesCharger, stations: stations)?.placeId == "places/ChIJabc")
    }

    @Test("a nearby supported station still matches when OCM and Places names differ")
    func proximityMatchesDifferentNames() {
        let stations = [
            station(name: "Gentari EV Hub", lat: 3.0, lon: 101.0, available: 1, total: 2)
        ]
        let ocmCharger = charger(id: "ocm-1", name: "JomCharge DC", lat: 3.0005, lon: 101.0005)

        #expect(ChargerStationMatching.match(ocmCharger, stations: stations)?.availableCount == 1)
    }

    @Test("two nearly equidistant stations at the same site yield no status instead of a guess")
    func equidistantStationsAreAmbiguous() {
        let stations = [
            station(name: "Operator A", lat: 3.0, lon: 101.0002, available: 0, total: 2),
            station(name: "Operator B", lat: 3.0002, lon: 101.0, available: 2, total: 2)
        ]
        let charger = charger(id: "ocm-1", name: "Unrelated OCM Label", lat: 3.0, lon: 101.0)

        #expect(ChargerStationMatching.match(charger, stations: stations) == nil)
    }

    @Test("nearest station wins when one candidate is clearly closer")
    func nearestWinsWhenDistinct() {
        let stations = [
            station(name: "Operator A", lat: 3.0, lon: 101.0002, available: 0, total: 2),   // ~22 m away
            station(name: "Operator B", lat: 3.002, lon: 101.0, available: 1, total: 2)     // ~222 m away
        ]
        let charger = charger(id: "ocm-1", name: "Unrelated OCM Label", lat: 3.0, lon: 101.0)

        let hit = ChargerStationMatching.match(charger, stations: stations)
        #expect(hit?.availableCount == 0)
        #expect(hit?.totalCount == 2)
    }
}
