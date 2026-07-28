import CoreDomain
import Foundation
import Testing
@testable import CoreOBD

/// Pins signal byte offsets against an independent implementation.
///
/// OVMS (`vehicle_hyundai_ioniq5/src/hif_can_poll.cpp`) decodes the same vehicle and was
/// developed separately against real cars. It indexes 0-based into a buffer with the
/// `62 xx xx` response header already stripped, while `SignalDef.startByte` is 0-based
/// into the payload with that header still present — so OVMS offset + 3 is our
/// startByte. Every signal both implementations read agrees under that conversion.
///
/// The reason to pin it: a wrong offset here does not fail loudly. It decodes to a
/// number in range and shows a plausible wrong reading in the UI. The HVAC pair below
/// was mislabelled for a long time on exactly that basis.
///
/// Mirrors `SpecCandidateProbeTest` in the Android repo — these move together.
struct SignalOffsetTests {

    /// OVMS offset + this = our `startByte`.
    static let ovmsOffsetShift = 3

    /// (request id, signal id) -> the offset OVMS reads it at.
    static let ovmsOffsets: [String: [String: Int]] = [
        "aircon": ["cabin_temp": 5, "ambient_temp": 6],
        "bms_01": [
            "soc_bms": 4, "pack_current": 10, "pack_voltage": 12,
            "temp_max": 14, "temp_min": 15,
            "cell_volt_max": 23, "cell_volt_min": 25
        ],
        "bms_05": ["soh": 25, "soc_display": 31],
        "odometer": ["odometer_km": 6],
        "tpms": [
            "tire_fl": 4, "tire_fl_temp": 5,
            "tire_fr": 9, "tire_fr_temp": 10,
            "tire_rl": 14, "tire_rl_temp": 15,
            "tire_rr": 19, "tire_rr_temp": 20
        ]
    ]

    private func loadProfile(_ asset: String) throws -> DecoderProfile {
        let url = try #require(
            ProfileParser.resourceBundle.url(forResource: asset, withExtension: "json"),
            "\(asset).json is not in the package bundle"
        )
        return try ProfileParser.parse(data: Data(contentsOf: url))
    }

    @Test("every bundled profile agrees with OVMS on shared signal offsets",
          arguments: Ioniq5Constants.bundledProfileAssets.sorted())
    func offsetsMatchOvms(asset: String) throws {
        let profile = try loadProfile(asset)

        for (requestId, signals) in Self.ovmsOffsets {
            guard let request = profile.requests.first(where: { $0.id == requestId }) else {
                continue  // Not every profile carries every request.
            }
            for (signalId, ovmsByte) in signals {
                guard let signal = request.signals.first(where: { $0.id == signalId }) else {
                    continue
                }
                let expected = ovmsByte + Self.ovmsOffsetShift
                #expect(
                    signal.startByte == expected,
                    "\(asset) \(requestId)/\(signalId): startByte \(signal.startByte), OVMS says \(expected)"
                )
            }
        }
    }

    /// Confirmed on the car: ambient is startByte 9, which settles startByte 8 as cabin.
    ///
    /// Previously ambient was read at startByte 8 and cabin at startByte 30 — so ambient
    /// reported cabin temperature, and cabin read a byte nothing corroborates. It went
    /// unnoticed because a parked, settled car has the two within a degree of each
    /// other; only forcing them apart exposes it.
    @Test("HVAC ambient and cabin offsets are not swapped",
          arguments: Ioniq5Constants.bundledProfileAssets.sorted())
    func hvacOffsetsNotSwapped(asset: String) throws {
        let profile = try loadProfile(asset)
        guard let aircon = profile.requests.first(where: { $0.id == "aircon" }) else { return }

        let ambient = try #require(aircon.signals.first { $0.id == "ambient_temp" })
        let cabin = try #require(aircon.signals.first { $0.id == "cabin_temp" })

        #expect(ambient.startByte == 9, "\(asset): ambient_temp moved")
        #expect(cabin.startByte == 8, "\(asset): cabin_temp moved")
    }

    /// A real 7B3/220100 frame captured while driving, at 25 km/h.
    ///
    /// Speed had no verified source for a long time: an earlier attempt read startByte
    /// 29 and saw a constant ~84, so the signal was dropped. Byte 29 really is a
    /// constant 84 — it holds that value across every frame of three captured drives —
    /// because the published offset counts from after the `62 01 00` header and was used
    /// without adding those three bytes back. Speed is startByte 32, which tracks the
    /// car: one capture runs 0,0,0,0,2,3,4,…,25,21,17,…,2,0 then climbs again.
    static let drivingFrame = Data([
        0x62, 0x01, 0x00, 0x7F, 0x94, 0x07, 0xC8, 0xFF,
        0x8B, 0x86, 0x66, 0x01, 0x11, 0x0F, 0x01, 0x10,
        0xFF, 0xFF, 0x0E, 0xFF, 0x0E, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0x2F, 0x54, 0x7B, 0x8C,
        0x19, 0xFF, 0xFF, 0x01, 0xFF, 0xFF, 0xFF, 0xAA, 0xAA
    ])

    @Test("speed decodes from a real driving frame")
    func speedDecodesFromRealFrame() throws {
        let profile = try loadProfile("ioniq5_84kwh")
        let aircon = try #require(profile.requests.first { $0.id == "aircon" })
        let speed = try #require(aircon.signals.first { $0.id == "speed_kph" })

        #expect(speed.startByte == 32)
        let decoded = try #require(
            DecoderEngine().decodeSignal(payload: Self.drivingFrame, signal: speed)
        )
        #expect(decoded == 25.0)
    }

    /// The offset that misled the earlier attempt, kept as the negative case so the
    /// mistake cannot quietly recur.
    @Test("byte 29 is the constant that the old speed guess read")
    func oldSpeedGuessIsAConstant() throws {
        let oldGuess = SignalDef(
            id: "speed_kph", startByte: 29, length: 1,
            formula: "A", unit: "km/h", min: 0, max: 250
        )
        let decoded = try #require(
            DecoderEngine().decodeSignal(payload: Self.drivingFrame, signal: oldGuess)
        )
        #expect(decoded == 84.0)
    }

    /// The tyre pressure formulas are the same conversion in different units — OVMS
    /// reports PSI as `raw / 5`, we report kPa as `raw * 1.379`. Guards against someone
    /// "simplifying" the constant.
    @Test("tyre pressure formula agrees with OVMS in kPa")
    func tyrePressureFormulaMatchesOvms() throws {
        let profile = try loadProfile("ioniq5_84kwh")
        let tpms = try #require(profile.requests.first { $0.id == "tpms" })
        let fl = try #require(tpms.signals.first { $0.id == "tire_fl" })

        let raw = 0xA7
        let ovmsKpa = (Double(raw) / 5.0) * 6.89476
        let ours = try #require(
            DecoderEngine().decodeSignal(
                payload: Data(repeating: UInt8(raw), count: fl.startByte + 1),
                signal: fl
            )
        )
        #expect(abs(ours - ovmsKpa) < 0.1, "ours \(ours) vs OVMS \(ovmsKpa)")
    }
}
