import CoreDomain
import Foundation
import Testing
@testable import CoreRouting

struct CalibrationSnapshotTests {

    @Test("factors round-trip through the persisted snapshot")
    func snapshotRoundTrip() {
        let factors = CalibrationFactors(
            crrScale: 1.2,
            cdaScale: 0.9,
            auxScale: 1.1,
            fittedSampleKm: 320
        )
        let restored = CalibrationFactors(snapshot: factors.snapshot)
        // The snapshot stores Float, so compare at Float precision.
        #expect(abs(restored.crrScale - 1.2) < 0.001)
        #expect(abs(restored.cdaScale - 0.9) < 0.001)
        #expect(abs(restored.auxScale - 1.1) < 0.001)
        #expect(abs(restored.fittedSampleKm - 320) < 0.001)
        #expect(restored.isApplicable)
    }

    @Test("an unset snapshot is not applicable and is neutral in the model")
    func unsetSnapshotIsNeutral() {
        let factors = CalibrationFactors(snapshot: .unset)
        #expect(!factors.isApplicable)

        // A model built from an unset snapshot must behave exactly like the
        // default model — no phantom calibration before any trip is fitted.
        let defaultModel = ConsumptionModel()
        let unsetModel = ConsumptionModel(calibration: factors)
        let energy = defaultModel.segmentEnergyKwh(
            distanceKm: 100, speedKph: 90, elevationGainM: 0, ambientC: 20
        )
        let unsetEnergy = unsetModel.segmentEnergyKwh(
            distanceKm: 100, speedKph: 90, elevationGainM: 0, ambientC: 20
        )
        #expect(unsetEnergy == energy)
    }

    @Test("a higher rolling-resistance fit costs more at city speeds")
    func crrScaleBitesAtLowSpeed() {
        let defaultModel = ConsumptionModel()
        let heavyFit = ConsumptionModel(calibration: CalibrationFactors(
            crrScale: 1.3, cdaScale: 1.0, auxScale: 1.0, fittedSampleKm: 500
        ))
        let flat = defaultModel.segmentEnergyKwh(
            distanceKm: 100, speedKph: 45, elevationGainM: 0, ambientC: 20
        )
        let fitted = heavyFit.segmentEnergyKwh(
            distanceKm: 100, speedKph: 45, elevationGainM: 0, ambientC: 20
        )
        #expect(fitted > flat)
    }

    @Test("a higher aero fit costs more at highway speeds")
    func cdaScaleBitesAtHighSpeed() {
        let defaultModel = ConsumptionModel()
        let aeroFit = ConsumptionModel(calibration: CalibrationFactors(
            crrScale: 1.0, cdaScale: 1.3, auxScale: 1.0, fittedSampleKm: 500
        ))
        let flat = defaultModel.segmentEnergyKwh(
            distanceKm: 100, speedKph: 120, elevationGainM: 0, ambientC: 20
        )
        let fitted = aeroFit.segmentEnergyKwh(
            distanceKm: 100, speedKph: 120, elevationGainM: 0, ambientC: 20
        )
        #expect(fitted > flat)
    }
}
