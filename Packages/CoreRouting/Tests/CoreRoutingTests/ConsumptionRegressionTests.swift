import Foundation
import Testing
@testable import CoreRouting

struct ChargeCurveRegressionTests {

    @Test("empty curve reports zero instead of crashing")
    func emptyCurveIsSafe() {
        let curve = ChargeCurve(curve: [])
        // Old code force-unwrapped curve.first! / curve.last! and crashed on an
        // empty (public-init) curve.
        #expect(curve.powerAtSoc(socPercent: 50) == 0)
        #expect(curve.chargeMinutes(fromSocPercent: 20, toSocPercent: 80, usableKwh: 77.4) == 0)
    }

    @Test("curve interpolates and clamps to the station limit")
    func normalInterpolation() {
        let curve = ChargeCurve(stationLimitKw: 100)
        #expect(curve.powerAtSoc(socPercent: 50) <= 100)
        #expect(curve.powerAtSoc(socPercent: 0) > 0)
        #expect(curve.energyAddedKwh(fromSocPercent: 50, toSocPercent: 80, usableKwh: 77.4) > 0)
    }
}

struct CalibrationUpdaterRegressionTests {

    @Test("zero measured energy must not ratchet the calibration down")
    func zeroEnergyIsRejected() {
        let updater = CalibrationUpdater()
        // A bad trip log / regen-only segment reports 0 kWh over real distance. The
        // old code drove ratio to the 0.3 floor and pushed the scales toward 0.7
        // permanently; it must be rejected outright.
        let result = updater.update(
            distanceKm: 50,
            speedKph: 100,
            elevationGainM: 0,
            ambientC: 20,
            actualEnergyKwh: 0
        )
        #expect(result.crrScale == 1.0)
        #expect(result.cdaScale == 1.0)
        #expect(result.fittedSampleKm == 0)
    }

    @Test("a sensible segment still calibrates")
    func sensibleSegmentCalibrates() {
        let updater = CalibrationUpdater()
        // Predicted at ~19 kWh/100 km over 50 km ≈ 9.5 kWh; feeding slightly more
        // actual energy should nudge the scales up a little.
        let result = updater.update(
            distanceKm: 50,
            speedKph: 100,
            elevationGainM: 0,
            ambientC: 20,
            actualEnergyKwh: 10.5
        )
        #expect(result.fittedSampleKm == 50)
        #expect(result.crrScale > 1.0 || result.cdaScale > 1.0)
    }
}
