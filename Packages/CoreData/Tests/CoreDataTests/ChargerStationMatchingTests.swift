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

    @Test("two nearly equidistant stations at the same site yield no status instead of a guess")
    func equidistantStationsAreAmbiguous() {
        let stations = [
            station(name: "ChargEV", lat: 3.0, lon: 101.0002, available: 0, total: 2),
            station(name: "ChargEV", lat: 3.0002, lon: 101.0, available: 2, total: 2)
        ]
        let charger = charger(id: "ocm-1", name: "ChargEV", lat: 3.0, lon: 101.0)

        #expect(ChargerStationMatching.match(charger, stations: stations) == nil)
    }

    @Test("nearest station wins when one candidate is clearly closer")
    func nearestWinsWhenDistinct() {
        let stations = [
            station(name: "ChargEV", lat: 3.0, lon: 101.0002, available: 0, total: 2),   // ~22 m away
            station(name: "ChargEV", lat: 3.002, lon: 101.0, available: 1, total: 2)     // ~222 m away
        ]
        let charger = charger(id: "ocm-1", name: "ChargEV", lat: 3.0, lon: 101.0)

        let hit = ChargerStationMatching.match(charger, stations: stations)
        #expect(hit?.availableCount == 0)
        #expect(hit?.totalCount == 2)
    }
}
