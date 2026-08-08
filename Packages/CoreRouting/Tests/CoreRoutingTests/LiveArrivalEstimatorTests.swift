import CoreDomain
import Foundation
import Testing
@testable import CoreRouting

struct LiveArrivalEstimatorTests {

    private let estimator = LiveArrivalEstimator()
    private let usableKwh = 77.4

    private func leg(
        distanceKm: Float = 100,
        elevationGainM: Float = 0,
        speedKph: Float = 95
    ) -> RemainingLeg {
        RemainingLeg(distanceKm: distanceKm, elevationGainM: elevationGainM, speedKph: speedKph)
    }

    @Test("baseline behavior reproduces the linear flat estimate")
    func baselineMatchesLinearMath() {
        let estimate = estimator.estimate(
            currentSocPercent: 80,
            usableKwh: usableKwh,
            remainingLegs: [leg()],
            ambientC: 20,
            liveKwhPer100Km: nil,
            learnedKwhPer100Km: nil,
            baselineKwhPer100Km: 19
        )
        // 100 km at 19 kWh/100 km over 77.4 kWh is 24.5 points: 80 − 24.5 ≈ 55.5.
        #expect(estimate?.predictedArrivalSocPercent ?? -1 > 54)
        #expect(estimate?.predictedArrivalSocPercent ?? 999 < 57)
        #expect(estimate?.kwhPer100KmUsed == 19)
    }

    @Test("a climb costs more than the same distance on flat ground")
    func elevationIncreasesEnergy() {
        let flat = estimator.estimate(
            currentSocPercent: 80,
            usableKwh: usableKwh,
            remainingLegs: [leg(elevationGainM: 0)],
            ambientC: 20,
            liveKwhPer100Km: nil,
            learnedKwhPer100Km: nil,
            baselineKwhPer100Km: 19
        )
        let climb = estimator.estimate(
            currentSocPercent: 80,
            usableKwh: usableKwh,
            remainingLegs: [leg(elevationGainM: 1500)],
            ambientC: 20,
            liveKwhPer100Km: nil,
            learnedKwhPer100Km: nil,
            baselineKwhPer100Km: 19
        )
        let flatKwh = flat?.legs.first?.kwhUsed ?? 0
        let climbKwh = climb?.legs.first?.kwhUsed ?? 0
        #expect(climbKwh > flatKwh)
        #expect(climb?.predictedArrivalSocPercent ?? 99 < flat?.predictedArrivalSocPercent ?? 0)
    }

    @Test("a thirsty live reading pulls the arrival down")
    func liveConsumptionRescales() {
        func estimate(live: Float) -> Float? {
            estimator.estimate(
                currentSocPercent: 80,
                usableKwh: usableKwh,
                remainingLegs: [leg()],
                ambientC: 20,
                liveKwhPer100Km: live,
                learnedKwhPer100Km: nil,
                baselineKwhPer100Km: 19
            )?.predictedArrivalSocPercent
        }
        #expect(estimate(live: 22)! < estimate(live: 19)!)
    }

    @Test("live wins over learned, which wins over baseline")
    func precedenceOrder() {
        func predict(live: Float?, learned: Float?) -> Float? {
            estimator.estimate(
                currentSocPercent: 80,
                usableKwh: usableKwh,
                remainingLegs: [leg()],
                ambientC: 20,
                liveKwhPer100Km: live,
                learnedKwhPer100Km: learned,
                baselineKwhPer100Km: 19
            )?.kwhPer100KmUsed
        }
        #expect(predict(live: 22, learned: 16) == 22)
        #expect(predict(live: nil, learned: 16) == 16)
        #expect(predict(live: nil, learned: nil) == 19)
    }

    @Test("a junk live reading is clamped, not trusted")
    func junkLiveIsClamped() {
        let model = ConsumptionModel()
        let flatKwh = model.segmentEnergyKwh(
            distanceKm: 100, speedKph: 95, elevationGainM: 0, ambientC: 20
        )
        // 100 kWh/100 km would imply scale 6×; the 2.0 clamp must bind.
        let estimate = estimator.estimate(
            currentSocPercent: 80,
            usableKwh: usableKwh,
            remainingLegs: [leg()],
            ambientC: 20,
            liveKwhPer100Km: 100,
            learnedKwhPer100Km: nil,
            baselineKwhPer100Km: 19
        )
        let expected = 80 - Float(flatKwh * 2.0 / usableKwh * 100)
        #expect(abs((estimate?.predictedArrivalSocPercent ?? -999) - expected) < 0.5)
    }

    @Test("empty or degenerate input reports nothing")
    func degenerateInputsAreQuiet() {
        let noLegs = estimator.estimate(
            currentSocPercent: 80,
            usableKwh: usableKwh,
            remainingLegs: [],
            ambientC: 20,
            liveKwhPer100Km: 19,
            learnedKwhPer100Km: nil,
            baselineKwhPer100Km: 19
        )
        #expect(noLegs == nil)

        let noCapacity = estimator.estimate(
            currentSocPercent: 80,
            usableKwh: 0,
            remainingLegs: [leg()],
            ambientC: 20,
            liveKwhPer100Km: 19,
            learnedKwhPer100Km: nil,
            baselineKwhPer100Km: 19
        )
        #expect(noCapacity == nil)
    }

    @Test("multi-leg trips break down per leg")
    func multiLegBreakdown() {
        let estimate = estimator.estimate(
            currentSocPercent: 90,
            usableKwh: usableKwh,
            remainingLegs: [
                leg(distanceKm: 60, elevationGainM: 400),
                leg(distanceKm: 40, elevationGainM: 0)
            ],
            ambientC: 20,
            liveKwhPer100Km: 18,
            learnedKwhPer100Km: nil,
            baselineKwhPer100Km: 19
        )
        #expect(estimate?.legs.count == 2)
        #expect(estimate?.legs.allSatisfy { $0.kwhUsed > 0 } == true)
        #expect(estimate?.predictedArrivalSocPercent ?? 0 > 0)
    }
}
