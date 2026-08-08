import CoreDomain
import Foundation
import Testing
@testable import CoreRouting

struct DestinationRangeAdvisorTests {

    private let advisor = DestinationRangeAdvisor()
    private let usableKwh = 77.4
    private let reserve: Float = 15

    private func charger(id: String, distanceKm: Double) -> RouteChargerCandidate {
        RouteChargerCandidate(
            charger: Charger(id: id, name: id, lat: 0, lon: 0, maxPowerKw: 200),
            driveKm: distanceKm
        )
    }

    /// Consumption 15.48 kWh/100 km over 77.4 kWh → exactly 0.2 SOC % per km.
    private func advise(
        soc: Float,
        distanceKm: Double,
        chargers: [RouteChargerCandidate],
        available: Set<String> = []
    ) -> RangeAdvice {
        advisor.advise(
            currentSocPercent: soc,
            usableKwh: usableKwh,
            consumptionKwhPer100Km: 15.48,
            distanceToDestinationKm: distanceKm,
            reserveSocPercent: reserve,
            availableChargerIds: available,
            chargers: chargers
        )
    }

    @Test("a destination reachable on the current charge needs no stop")
    func directReachNeedsNoStop() {
        // 200 km × 0.2 %/km = 40 points: 50% → 10% is under reserve, but
        // 90% → 50% clears it comfortably.
        let advice = advise(soc: 90, distanceKm: 200, chargers: [])
        #expect(advice.canReachDirectly)
        #expect(advice.suggestedStop == nil)
        #expect(advice.predictedArrivalSocPercent == 50)
    }

    @Test("suggests a stop that tops up enough to reach the destination")
    func suggestsReachingStop() {
        // 50% start, 200 km: direct arrival 10% < 15% reserve.
        // Charger at 30 km: arrive 44%, +10 → depart 54%, remaining 170 km
        // burns 34 → arrive destination 20%.
        let advice = advise(
            soc: 50,
            distanceKm: 200,
            chargers: [charger(id: "A", distanceKm: 30)]
        )
        #expect(!advice.canReachDirectly)
        let stop = advice.suggestedStop
        #expect(stop != nil)
        #expect(stop?.reachesDestination == true)
        #expect(stop?.arriveSocPercent ?? -1 > 43)
        #expect(stop?.departSocPercent ?? -1 > 53)
        #expect(stop?.arriveDestinationSocPercent ?? -1 >= 19)
        #expect(stop?.chargeMinutes ?? 0 > 0)
    }

    @Test("a stop that cannot reach the destination is still offered as best effort")
    func bestEffortWhenNothingReaches() {
        // Consumption 30.96 kWh/100 km → 0.4 %/km. 300 km burns 120 points,
        // so 40% start arrives at −80%. A charger at 50 km (arrive 20%) can
        // only charge to the 80% target, leaving 250 km × 0.4 = 100 burned →
        // arrives at −20%: short, but the only usable stop.
        let advice = advisor.advise(
            currentSocPercent: 40,
            usableKwh: usableKwh,
            consumptionKwhPer100Km: 30.96,
            distanceToDestinationKm: 300,
            reserveSocPercent: reserve,
            availableChargerIds: [],
            chargers: [charger(id: "A", distanceKm: 50)]
        )
        #expect(!advice.canReachDirectly)
        #expect(advice.suggestedStop?.reachesDestination == false)
        #expect(advice.suggestedStop?.departSocPercent == 80)
    }

    @Test("unreachable and past-the-destination chargers are excluded")
    func excludesUnusableChargers() {
        // 0.2 %/km, 40% start, 200 km → direct arrival 0% < reserve.
        // Charger at 250 km is past the destination — it cannot get you there.
        // Charger at 210 km is both past the destination and unreachable
        // (arrive < 0 on this charge).
        let advice = advise(
            soc: 40,
            distanceKm: 200,
            chargers: [
                charger(id: "far", distanceKm: 250),
                charger(id: "past", distanceKm: 210)
            ]
        )
        #expect(!advice.canReachDirectly)
        #expect(advice.suggestedStop == nil)
    }

    @Test("live-available chargers win the tie")
    func availableChargerWinsTie() {
        let a = charger(id: "A", distanceKm: 30)
        let b = charger(id: "B", distanceKm: 30)
        let advice = advise(
            soc: 50,
            distanceKm: 200,
            chargers: [a, b],
            available: ["B"]
        )
        #expect(advice.suggestedStop?.charger.id == "B")
    }

    @Test("a full stop is still a candidate when nothing else exists")
    func fullChargerIsFallback() {
        let advice = advise(
            soc: 50,
            distanceKm: 200,
            chargers: [charger(id: "A", distanceKm: 30)],
            available: []
        )
        #expect(advice.suggestedStop?.charger.id == "A")
    }

    @Test("degenerate inputs never raise a false alarm")
    func degenerateInputsAreQuiet() {
        let advice = advisor.advise(
            currentSocPercent: 50,
            usableKwh: 0,
            consumptionKwhPer100Km: 15,
            distanceToDestinationKm: 100,
            reserveSocPercent: 15,
            chargers: []
        )
        #expect(advice.canReachDirectly)
        #expect(advice.suggestedStop == nil)
    }

    @Test("an elevation-aware override can flag a route the flat math calls fine")
    func elevationOverrideWinsOverFlatMath() {
        // Flat math: 50% over 100 km at 0.2 %/km arrives at 30% — reachable,
        // so the advisor would stay silent. But the caller's elevation-aware
        // prediction says 8%: the advisor must still hunt for a stop and
        // report the overridden arrival.
        let advice = advisor.advise(
            currentSocPercent: 50,
            usableKwh: usableKwh,
            consumptionKwhPer100Km: 15.48,
            distanceToDestinationKm: 100,
            reserveSocPercent: reserve,
            predictedArrivalSocPercent: 8,
            chargers: [charger(id: "A", distanceKm: 20)]
        )
        #expect(!advice.canReachDirectly)
        #expect(advice.predictedArrivalSocPercent == 8)
        let stop = advice.suggestedStop
        #expect(stop != nil)
        #expect(stop?.reachesDestination == true)
    }
}
