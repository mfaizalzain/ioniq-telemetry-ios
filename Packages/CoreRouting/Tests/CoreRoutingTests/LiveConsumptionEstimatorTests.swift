import CoreDomain
import Foundation
import Testing
@testable import CoreRouting

struct LiveConsumptionEstimatorTests {

    private func sample(
        speedKph: Float,
        powerKw: Float,
        secondsAgo: TimeInterval = 1,
        charging: Bool = false
    ) -> VehicleTelemetry {
        VehicleTelemetry(
            timestamp: Date().addingTimeInterval(-secondsAgo),
            powerKw: powerKw,
            speedKph: speedKph,
            isCharging: charging
        )
    }

    @Test("stays silent until enough valid samples")
    func requiresMinimumSamples() {
        let estimator = LiveConsumptionEstimator()
        for _ in 0..<(LiveConsumptionEstimator.minSamples - 1) {
            estimator.update(sample(speedKph: 100, powerKw: 30))
        }
        #expect(estimator.kwhPer100Km == nil)
        estimator.update(sample(speedKph: 100, powerKw: 30))
        #expect(estimator.kwhPer100Km != nil)
    }

    @Test("averages plausible power/speed into kWh per 100 km")
    func averagesPlausibleSamples() {
        let estimator = LiveConsumptionEstimator()
        // 40 kW at 100 km/h is exactly 40 kWh/100 km.
        for _ in 0..<LiveConsumptionEstimator.minSamples {
            estimator.update(sample(speedKph: 100, powerKw: 40))
        }
        #expect(estimator.kwhPer100Km ?? -1 > 39)
        #expect(estimator.kwhPer100Km ?? 999 < 41)
    }

    @Test("ignores idle creep below the speed floor")
    func ignoresLowSpeed() {
        let estimator = LiveConsumptionEstimator()
        for _ in 0..<LiveConsumptionEstimator.minSamples {
            estimator.update(sample(speedKph: 3, powerKw: 1))
        }
        #expect(estimator.kwhPer100Km == nil)
    }

    @Test("ignores charging frames and regen (negative power)")
    func ignoresChargingAndRegen() {
        let estimator = LiveConsumptionEstimator()
        for _ in 0..<LiveConsumptionEstimator.minSamples {
            estimator.update(sample(speedKph: 90, powerKw: -25, charging: false))
        }
        for _ in 0..<LiveConsumptionEstimator.minSamples {
            estimator.update(sample(speedKph: 90, powerKw: 25, charging: true))
        }
        #expect(estimator.kwhPer100Km == nil)
    }

    @Test("rejects junk samples outside the plausible band")
    func rejectsJunkSamples() {
        let estimator = LiveConsumptionEstimator()
        for _ in 0..<LiveConsumptionEstimator.minSamples {
            // 400 kW at 10 km/h → 4000 kWh/100 km — a bad frame.
            estimator.update(sample(speedKph: 10, powerKw: 400))
        }
        #expect(estimator.kwhPer100Km == nil)
    }

    @Test("a stale gap restarts the window")
    func staleGapResets() {
        let estimator = LiveConsumptionEstimator()
        for _ in 0..<LiveConsumptionEstimator.minSamples {
            estimator.update(sample(speedKph: 100, powerKw: 30, secondsAgo: 1))
        }
        #expect(estimator.kwhPer100Km != nil)

        // A frame a minute later means the drive ended and restarted. The reset
        // wipes the sample count, so minSamples-1 more fresh frames must not be
        // enough to report — proving the old window did not carry over.
        estimator.update(sample(speedKph: 100, powerKw: 30, secondsAgo: 60))
        for _ in 0..<(LiveConsumptionEstimator.minSamples - 1) {
            estimator.update(sample(speedKph: 100, powerKw: 30, secondsAgo: 1))
        }
        #expect(estimator.kwhPer100Km == nil)
    }
}
