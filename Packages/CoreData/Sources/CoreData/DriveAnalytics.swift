import Foundation

/// Simple per-drive energy analytics derived from logged samples.
public struct DriveAnalytics: Sendable, Equatable {
    public let grossConsumedKwh: Double
    public let regenKwh: Double
    public let netConsumedKwh: Double
    public let regenSharePercent: Float
    public let hasData: Bool

    public var regenRating: String {
        switch true {
        case !hasData: return "No data"
        case regenSharePercent >= 25: return "Excellent"
        case regenSharePercent >= 15: return "Good"
        case regenSharePercent >= 7: return "Fair"
        default: return "Low"
        }
    }

    public init(
        grossConsumedKwh: Double,
        regenKwh: Double,
        netConsumedKwh: Double,
        regenSharePercent: Float,
        hasData: Bool
    ) {
        self.grossConsumedKwh = grossConsumedKwh
        self.regenKwh = regenKwh
        self.netConsumedKwh = netConsumedKwh
        self.regenSharePercent = regenSharePercent
        self.hasData = hasData
    }
}

private let movingKph: Float = 3
private let maxGapHours: Double = 60.0 / 3600.0

public func analyzeDrive(samples: [SampleEntity]) -> DriveAnalytics {
    var consumed = 0.0
    var regen = 0.0

    for i in 1..<samples.count {
        let prev = samples[i - 1]
        let cur = samples[i]
        guard let power = cur.powerKw else { continue }
        let dtHours = cur.timestamp.timeIntervalSince(prev.timestamp) / 3600.0
        if dtHours <= 0.0 || dtHours > maxGapHours { continue }

        let energy = Double(power) * dtHours
        if power < 0 {
            consumed += -energy
        } else {
            let moving = cur.speedKph == nil || cur.speedKph! > movingKph
            if moving { regen += energy }
        }
    }

    let hasData = consumed > 0.0 || regen > 0.0
    let share: Float = consumed > 0.0 ? Float(regen / consumed * 100.0) : 0
    return DriveAnalytics(
        grossConsumedKwh: consumed,
        regenKwh: regen,
        netConsumedKwh: consumed - regen,
        regenSharePercent: share,
        hasData: hasData
    )
}
