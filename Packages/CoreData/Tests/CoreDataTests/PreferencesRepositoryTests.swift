import CoreDomain
import Foundation
import Testing
@testable import CoreData

/// Round-trips the persisted calibration through UserDefaults. Deliberately
/// small: the repository is a thin layer over the defaults, so this proves the
/// four keys survive a save/load without asserting anything about the model.
@Suite("PreferencesRepository calibration persistence", .serialized)
struct PreferencesRepositoryTests {

    private let calibrationKeys = [
        "calibrationCrrScale",
        "calibrationCdaScale",
        "calibrationAuxScale",
        "calibrationFittedKm",
    ]

    @Test("calibration survives a save and reload")
    func calibrationRoundTrips() async {
        let repo = PreferencesRepositoryImpl()
        let fitted = CalibrationSnapshot(
            crrScale: 1.17,
            cdaScale: 1.02,
            auxScale: 0.94,
            fittedSampleKm: 412
        )
        await repo.update { prefs in
            var next = prefs
            next.calibration = fitted
            return next
        }

        // A fresh instance reloads from the same defaults.
        let reloaded = PreferencesRepositoryImpl()
        #expect(reloaded.currentPreferences.calibration == fitted)

        // Restore the unset state so the test leaves no footprint.
        await reloaded.update { prefs in
            var next = prefs
            next.calibration = .unset
            return next
        }
        let clean = PreferencesRepositoryImpl()
        #expect(clean.currentPreferences.calibration == .unset)

        for key in calibrationKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    @Test("a fresh install has no calibration until fitted")
    func freshInstallIsUnset() {
        for key in calibrationKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        let repo = PreferencesRepositoryImpl()
        #expect(repo.currentPreferences.calibration == .unset)
        #expect(!repo.currentPreferences.calibration.isSet)
    }

    @Test("Google charger source falls back to OCM without a Maps key")
    func googleChargerSourceRequiresMapsKey() {
        let withoutKey = UserPreferences(googleMapsApiKey: " \n", chargerSource: .googlePlaces)
        #expect(withoutKey.chargerSourceOrDefault == .openChargeMap)

        let withKey = UserPreferences(googleMapsApiKey: "maps-key", chargerSource: .googlePlaces)
        #expect(withKey.chargerSourceOrDefault == .googlePlaces)
    }
}
