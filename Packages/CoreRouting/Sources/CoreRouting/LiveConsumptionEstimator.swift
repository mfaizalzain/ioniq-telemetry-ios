import CoreDomain
import Foundation

/// Rolling live consumption from OBD power and speed.
///
/// Instantaneous consumption is P[kW] / v[km/h] × 100. A single frame is noisy —
/// regen, junctions, HVAC cycling — so the estimator keeps an exponential moving
/// average and stays silent until it has seen enough valid samples to be stable.
///
/// Negative-power frames (regen) are deliberately excluded: crediting regen
/// overstates range, and the failure mode of a range estimate must be
/// conservative, not optimistic.
public final class LiveConsumptionEstimator: @unchecked Sendable {

    /// Samples needed before the estimate is offered as "live".
    public static let minSamples: Int = 12
    /// Below this speed a kW draw is mostly idle creep, not driving consumption.
    public static let minSpeedKph: Float = 8
    /// Sanity band for a single sample; anything outside is a bad frame.
    public static let plausibleSampleRange: ClosedRange<Double> = 5...45
    /// EMA gain — at ~1–2 Hz telemetry this is a ~10–30 s time constant.
    private static let alpha: Double = 1.0 / 30.0
    /// A frame this much older than the last accepted one restarts the window
    /// (the drive ended, or the session was torn down).
    private static let staleFrameAge: TimeInterval = 30

    private var average: Double?
    private var sampleCount = 0
    private var lastAcceptedAt: Date?

    public init() {}

    /// Current live consumption in kWh/100 km, or nil before enough samples exist.
    public var kwhPer100Km: Float? {
        guard sampleCount >= Self.minSamples, let average else { return nil }
        return Float(average)
    }

    public func update(_ telemetry: VehicleTelemetry) {
        guard !telemetry.isCharging else { return }
        guard let speed = telemetry.speedKph, speed >= Self.minSpeedKph else { return }
        guard let powerKw = telemetry.powerKw, powerKw > 0 else { return }

        if let last = lastAcceptedAt, telemetry.timestamp.timeIntervalSince(last) > Self.staleFrameAge {
            reset()
        }
        lastAcceptedAt = telemetry.timestamp

        let consumption = Double(powerKw) / Double(speed) * 100.0
        guard Self.plausibleSampleRange.contains(consumption) else { return }

        if let average {
            self.average = average + Self.alpha * (consumption - average)
        } else {
            average = consumption
        }
        sampleCount += 1
    }

    public func reset() {
        average = nil
        sampleCount = 0
        lastAcceptedAt = nil
    }
}
