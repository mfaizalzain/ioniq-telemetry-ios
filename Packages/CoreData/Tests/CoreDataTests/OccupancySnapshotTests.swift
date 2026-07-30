import Foundation
import Testing
@testable import CoreData

/// The snapshot decides what "full" means, and the occupancy alert is only as
/// trustworthy as that. Mirrors Android's `OccupancySnapshot` semantics:
/// `hasStatus` = at least one station reported, `allOccupied` = every station that
/// reported has no free connector.
@Suite("OccupancySnapshot")
struct OccupancySnapshotTests {

    private func station(available: Int, total: Int = 4) -> OccupancySnapshot.Station {
        OccupancySnapshot.Station(name: "S", availableCount: available, totalCount: total)
    }

    @Test("no stations reporting means no status, and never 'all occupied'")
    func emptyIsNotOccupied() {
        let snapshot = OccupancySnapshot(stations: [])
        #expect(!snapshot.hasStatus)
        #expect(!snapshot.allOccupied, "'no data' must not read as 'full'")
    }

    @Test("every station full means all occupied")
    func allFull() {
        let snapshot = OccupancySnapshot(stations: [station(available: 0), station(available: 0)])
        #expect(snapshot.hasStatus)
        #expect(snapshot.allOccupied)
    }

    @Test("one free connector anywhere means not all occupied")
    func oneFree() {
        let snapshot = OccupancySnapshot(stations: [station(available: 0), station(available: 1)])
        #expect(snapshot.hasStatus)
        #expect(!snapshot.allOccupied)
    }

    /// Regression: `isOccupied` used to require `totalCount > 0`, so a station
    /// reporting zero available without a connector count read as *not* occupied and
    /// suppressed the alert for the whole stop.
    @Test("zero available counts as occupied even without a connector count")
    func occupiedWithoutTotal() {
        let snapshot = OccupancySnapshot(stations: [station(available: 0, total: 0)])
        #expect(snapshot.allOccupied)
    }

    @Test("a mix of full stations, one lacking a connector count, is still all occupied")
    func mixedMissingTotals() {
        let snapshot = OccupancySnapshot(stations: [
            station(available: 0, total: 4),
            station(available: 0, total: 0),
        ])
        #expect(snapshot.allOccupied)
    }
}
