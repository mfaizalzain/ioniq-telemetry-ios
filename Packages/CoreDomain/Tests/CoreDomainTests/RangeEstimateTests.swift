import Testing
@testable import CoreDomain

/// The dashboard's range figure was previously `soc * 4.2` — a constant that
/// ignored the vehicle profile, the driver's own consumption and the unit system.
/// These pin the ported behaviour to Android's `RangeEstimate.kt`.
struct RangeEstimateTests {

    @Test("unknown SOC yields no estimate, not a zero-length range")
    func unknownSocIsNil() {
        #expect(estimateRange(socPercent: nil, usableKwh: 77.4) == nil)
    }

    @Test("without trip history the nominal figure is used and labelled as such")
    func fallsBackToNominal() throws {
        let estimate = try #require(estimateRange(socPercent: 100, usableKwh: 77.4))
        #expect(estimate.source == .nominal)
        #expect(estimate.kwhPer100km == nominalKwhPer100Km)
        // 77.4 kWh at 18 kWh/100 km
        #expect(abs(estimate.distanceKm - 430) < 1)
    }

    @Test("measured consumption wins outright and is marked measured")
    func measuredWins() throws {
        let estimate = try #require(
            estimateRange(socPercent: 50, usableKwh: 77.4, measuredKwhPer100km: 20)
        )
        #expect(estimate.source == .measured)
        // Half of 77.4 kWh at 20 kWh/100 km
        #expect(abs(estimate.distanceKm - 193.5) < 0.5)
    }

    @Test("pack capacity changes the answer — the point of reading the profile")
    func capacityMatters() throws {
        let small = try #require(estimateRange(socPercent: 100, usableKwh: 58))
        let large = try #require(estimateRange(socPercent: 100, usableKwh: 84))
        #expect(small.distanceKm < large.distanceKm)
    }

    /// A zero or negative measured figure is not a consumption reading, and
    /// dividing by it would produce an infinite range.
    @Test("a non-positive measured figure is ignored", arguments: [Float(0), -5])
    func nonPositiveMeasuredIgnored(measured: Float) throws {
        let estimate = try #require(
            estimateRange(socPercent: 80, usableKwh: 77.4, measuredKwhPer100km: measured)
        )
        #expect(estimate.source == .nominal)
        #expect(estimate.distanceKm.isFinite)
    }

    @Test("SOC is clamped, so bad decoder output cannot inflate the range")
    func socClamped() throws {
        let over = try #require(estimateRange(socPercent: 140, usableKwh: 77.4))
        let full = try #require(estimateRange(socPercent: 100, usableKwh: 77.4))
        #expect(abs(over.distanceKm - full.distanceKm) < 0.01)

        let under = try #require(estimateRange(socPercent: -10, usableKwh: 77.4))
        #expect(under.distanceKm == 0)
    }
}
