import Foundation

// MARK: - Range Estimate
//
// Ported from Android's `RangeEstimate.kt`. Deliberately separate from the
// charger-reach estimator in `CarPlayCoordinator` (which mirrors Android Auto's
// `ChargerReach.kt`): that one adjusts a 19 kWh/100 km baseline for ambient
// temperature because it decides whether a charger is reachable, while this one
// answers the dashboard's simpler question and says plainly when it is guessing.

/// Remaining driving range shown on the dashboard hero card.
///
/// The estimate is only as good as the consumption figure behind it, and the two
/// available figures are not equally trustworthy — so the source travels with the
/// number and the UI labels it. A driver who knows the range came from their own
/// logged trips reads it very differently from a factory-ish default.
public struct RangeEstimate: Equatable, Sendable {
    public let distanceKm: Float
    public let kwhPer100km: Float
    public let source: RangeSource

    public init(distanceKm: Float, kwhPer100km: Float, source: RangeSource) {
        self.distanceKm = distanceKm
        self.kwhPer100km = kwhPer100km
        self.source = source
    }
}

public enum RangeSource: Sendable {
    /// Derived from the driver's own logged trips.
    case measured

    /// No usable trip history yet — a mixed-driving default for the platform.
    case nominal
}

/// E-GMP mixed-driving consumption, used until the driver has logged enough
/// distance to speak for itself. Deliberately pessimistic-ish: overestimating
/// range is the failure mode that leaves someone stranded.
public let nominalKwhPer100Km: Float = 18

/// Trip distance needed before measured efficiency replaces `nominalKwhPer100Km`.
///
/// A handful of short urban hops averages nothing like the driver's real
/// consumption — cold-start HVAC dominates them — so a single trip must not be
/// allowed to set the range figure.
public let minMeasuredKm: Float = 50

/// How far back trip history is read when measuring the driver's own consumption.
public let measuredConsumptionWindow: TimeInterval = 30 * 24 * 60 * 60

/// Remaining range for `socPercent` of a `usableKwh` pack.
///
/// Pass `measuredKwhPer100km` only when it is backed by at least `minMeasuredKm`
/// of logged driving; callers get `.nominal` otherwise. Returns nil when SOC is
/// unknown, because a dash reading "0 km" and a dash reading "no data" must not
/// look the same.
public func estimateRange(
    socPercent: Float?,
    usableKwh: Float,
    measuredKwhPer100km: Float? = nil
) -> RangeEstimate? {
    guard let socPercent else { return nil }

    let measured = measuredKwhPer100km.flatMap { $0 > 0 ? $0 : nil }
    let consumption = measured ?? nominalKwhPer100Km
    let source: RangeSource = measured != nil ? .measured : .nominal

    let remainingKwh = usableKwh * min(max(socPercent, 0), 100) / 100
    let distanceKm = remainingKwh / consumption * 100

    return RangeEstimate(
        distanceKm: max(distanceKm, 0),
        kwhPer100km: consumption,
        source: source
    )
}
