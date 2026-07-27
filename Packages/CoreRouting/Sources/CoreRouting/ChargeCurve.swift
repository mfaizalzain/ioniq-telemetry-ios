import Foundation

// MARK: - Charge curve data

/// Measured Ioniq 5 800 V DC charge curve — flat and high until ~65% SOC, then a
/// sharp taper (spec §4.4). SOC % to peak kW.
public let ioniq5DcCurve: [(Int, Float)] = [
    (0, 180), (10, 220), (20, 235), (30, 233),
    (40, 225), (50, 198), (60, 165), (70, 120),
    (80, 85),  (90, 55),  (100, 20),
]

// MARK: - Temperature derating

/// Pack-temperature derate. A cold pack roughly triples charge time.
public func derateForTemp(packTempC: Float) -> Float {
    switch packTempC {
    case ..<0:  return 0.35
    case ..<10: return 0.55
    case ..<15: return 0.80
    case ..<35: return 1.00
    case ..<45: return 0.85
    default:    return 0.60
    }
}

// MARK: - ChargeCurve

public struct ChargeCurve: Sendable {
    private let curve: [(Int, Float)]
    private let stationLimitKw: Float

    public init(
        curve: [(Int, Float)] = ioniq5DcCurve,
        stationLimitKw: Float = .greatestFiniteMagnitude
    ) {
        self.curve = curve
        self.stationLimitKw = stationLimitKw
    }

    /// Interpolated charge power at a given SOC.
    public func powerAtSoc(socPercent: Float) -> Float {
        let clamped = min(max(socPercent, 0), 100)
        let upper = curve.first(where: { Float($0.0) >= clamped }) ?? curve.last!
        let lower = curve.last(where: { Float($0.0) <= clamped }) ?? curve.first!
        let interpolated: Float
        if upper.0 == lower.0 {
            interpolated = upper.1
        } else {
            let t = (clamped - Float(lower.0)) / Float(upper.0 - lower.0)
            interpolated = lower.1 + t * (upper.1 - lower.1)
        }
        return min(interpolated, stationLimitKw)
    }

    /// Charge time as the numerical integral of energy over available power,
    /// stepped at 1% SOC:  t = Σ (E_usable × 0.01) / (P(soc) × derate(T)).
    public func chargeMinutes(
        fromSocPercent: Float,
        toSocPercent: Float,
        usableKwh: Double,
        packTempC: Float = 25
    ) -> Int {
        if toSocPercent <= fromSocPercent { return 0 }
        let derate = derateForTemp(packTempC: packTempC)
        var hours: Double = 0
        var soc = fromSocPercent
        while soc < toSocPercent {
            let step = min(1, toSocPercent - soc)
            let power = max(powerAtSoc(socPercent: soc) * derate, 1)
            hours += (usableKwh * Double(step) / 100.0) / Double(power)
            soc += step
        }
        return Int(hours * 60)
    }

    /// Energy added when charging from one SOC to another.
    public func energyAddedKwh(
        fromSocPercent: Float, toSocPercent: Float, usableKwh: Double
    ) -> Float {
        Float(max(toSocPercent - fromSocPercent, 0) / 100.0 * Float(usableKwh))
    }
}
