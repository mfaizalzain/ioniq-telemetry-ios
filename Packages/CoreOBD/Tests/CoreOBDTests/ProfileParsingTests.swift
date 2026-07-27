import CoreDomain
import Foundation
import Testing
@testable import CoreOBD

/// Every bundled profile must decode. These shipped broken for a while because
/// `signed` is omitted from most signals and the synthesized decoder required it,
/// which failed silently and left the poller with zero requests.
struct ProfileParsingTests {

    @Test("every bundled profile decodes", arguments: Ioniq5Constants.bundledProfileAssets.sorted())
    func bundledProfileDecodes(asset: String) throws {
        let url = try #require(
            ProfileParser.resourceBundle.url(forResource: asset, withExtension: "json"),
            "\(asset).json is not in the package bundle"
        )
        let profile = try ProfileParser.parse(data: Data(contentsOf: url))

        #expect(!profile.requests.isEmpty)
        #expect(profile.usableCapacityKwh > 0)
        for request in profile.requests {
            #expect(!request.signals.isEmpty, "\(request.id) has no signals")
            #expect(!request.header.isEmpty)
        }
    }

    @Test("signed defaults to false when the key is absent")
    func signedDefaultsToFalse() throws {
        let json = """
        {"id": "soc", "startByte": 7, "length": 1, "formula": "A/2", "unit": "%"}
        """
        let signal = try JSONDecoder().decode(SignalDef.self, from: Data(json.utf8))
        #expect(signal.signed == false)
        #expect(signal.min == nil)
    }

    @Test("signed is honoured when present")
    func signedHonoured() throws {
        let json = """
        {"id": "cur", "startByte": 13, "length": 2, "formula": "A", "unit": "A", "signed": true}
        """
        let signal = try JSONDecoder().decode(SignalDef.self, from: Data(json.utf8))
        #expect(signal.signed)
    }

    /// Guards the catalog→profile mapping: a vehicle the picker offers but that
    /// resolves to no bundled profile would decode nothing at runtime.
    @Test("every catalog vehicle resolves to a bundled profile")
    func everyVehicleResolves() {
        for vehicle in Ioniq5Constants.allVehicles {
            let asset = Ioniq5Constants.decoderProfileAsset(for: vehicle.id)
            #expect(asset != nil, "\(vehicle.id) resolves to no profile")
            if let asset {
                #expect(Ioniq5Constants.bundledProfileAssets.contains(asset))
            }
        }
    }

    @Test("an unknown vehicle id resolves to nothing")
    func unknownVehicleResolvesToNil() {
        #expect(Ioniq5Constants.decoderProfileAsset(for: "tesla_model_3") == nil)
    }
}
