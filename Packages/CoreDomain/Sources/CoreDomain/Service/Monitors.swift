import Foundation

// MARK: - ParkedStateEvaluator

/// Turns the per-frame speed `DriveMonitor` produces into a stable parked/driving
/// verdict.
///
/// Two properties matter more than precision. **Asymmetric transitions**: becoming
/// `.driving` is instant, becoming `.parked` needs `parkedConfirm` without motion
/// evidence — the expensive error is calling a moving car parked. **No flicker**: a
/// gate that flipped at a stop light would pop UI in and out of existence, which is
/// the very distraction the gate exists to prevent.
///
/// Not thread-safe; drive it from the same single consumer as `DriveMonitor`.
public final class ParkedStateEvaluator {

    /// Same value as `DriveMonitor.movementSpeedKph`, deliberately: the app should
    /// not hold two different opinions about what "moving" means.
    public static let movingSpeedKph = DriveMonitor.movementSpeedKph

    /// Long enough that stop-start traffic doesn't unlock a gated surface mid-drive;
    /// short enough that a driver who has actually parked isn't left waiting.
    public static let parkedConfirm: TimeInterval = 10

    public private(set) var current: ParkedState = .unknown

    private let parkedConfirm: TimeInterval
    private var lastMotionAt: Date?

    public init(parkedConfirm: TimeInterval = ParkedStateEvaluator.parkedConfirm) {
        self.parkedConfirm = parkedConfirm
    }

    /// Folds one frame in and returns the resulting state.
    ///
    /// - Parameter speedKph: the speed `DriveMonitor` derived, or nil when it could
    ///   not tell. **Nil is not zero**: it means the odometer says the car is
    ///   covering ground but GPS has gone stale (a tunnel). Treating that as
    ///   stationary would report a car at motorway speed as parked, so a nil frame
    ///   holds the current state and refuses to accrue dwell toward `.parked`.
    /// - Parameter connected: with no adapter there is no vehicle to have a motion
    ///   state, so the answer is `.unknown` — which must not collapse into "moving".
    @discardableResult
    public func onFrame(speedKph: Float?, connected: Bool, charging: Bool = false, now: Date = Date()) -> ParkedState {
        guard connected else {
            lastMotionAt = nil
            current = .unknown
            return current
        }

        // First connected frame: start the dwell clock. Otherwise a car already
        // stationary when the adapter connected would never accumulate the dwell it
        // needs and would sit in .unknown for the whole session.
        if lastMotionAt == nil { lastMotionAt = now }

        if speedKph == nil {
            lastMotionAt = now                      // no evidence: hold, don't accrue
        } else if let speed = speedKph, speed > Self.movingSpeedKph {
            lastMotionAt = now
            current = .driving
        } else if let since = lastMotionAt, now.timeIntervalSince(since) >= parkedConfirm {
            current = charging ? .charging : .parked
        }
        // Otherwise: below the threshold but inside the settle window — hold.

        return current
    }

    public func reset() {
        lastMotionAt = nil
        current = .unknown
    }
}

public extension ParkedState {
    /// Whether a surface may show attention-heavy UI. Only a confirmed stationary
    /// car qualifies — `.unknown` must not read as permission.
    var allowsAttentionHeavyUi: Bool {
        self == .parked || self == .charging
    }
}

// MARK: - ChargeAlertMonitor

/// Fires charging milestone alerts, once each per session.
///
/// Crossing detection rather than level detection, so plugging in at 85% only fires
/// the 100% alert. Flags reset when charging stops.
public final class ChargeAlertMonitor {
    private let thresholds: [Float]
    private let onAlert: (Float, Float) -> Void

    private var wasCharging = false
    private var lastSoc: Float?
    private var fired: Set<Float> = []

    public init(thresholds: [Float] = [80, 100], onAlert: @escaping (Float, Float) -> Void) {
        self.thresholds = thresholds
        self.onAlert = onAlert
    }

    public func onTelemetry(_ telemetry: VehicleTelemetry) {
        // Ignore regen — only stationary charging counts.
        if let speed = telemetry.speedKph, speed > 3 { return }

        let soc = telemetry.socDisplay ?? telemetry.socBms

        guard telemetry.isCharging else {
            if wasCharging {                        // session ended — re-arm
                fired.removeAll()
                lastSoc = nil
            }
            wasCharging = false
            return
        }

        guard wasCharging else {                    // session just started
            fired.removeAll()
            lastSoc = soc
            wasCharging = true
            return
        }

        guard let soc else { return }
        let previous = lastSoc
        lastSoc = soc

        for threshold in thresholds where !fired.contains(threshold) {
            let crossed = previous.map { $0 < threshold && soc >= threshold } ?? false
            // A session that starts mid-poll exactly at full still alerts.
            let reachedFull = threshold >= 100 && soc >= 100
            if crossed || reachedFull {
                fired.insert(threshold)
                onAlert(threshold, soc)
            }
        }
    }
}

// MARK: - TirePressureMonitor

/// Fires a low-pressure alert when any wheel drops below `minKpa`.
///
/// Edge-triggered per wheel: a wheel alerts once when it first goes low and only
/// re-arms after climbing above `minKpa + hysteresisKpa`, so a pressure hovering at
/// the threshold can't spam notifications.
public final class TirePressureMonitor {
    private let minKpa: Float
    private let hysteresisKpa: Float
    private let onAlert: ([(String, Int)]) -> Void

    private var alerted: Set<String> = []

    public init(
        minKpa: Float = 220,
        hysteresisKpa: Float = 10,
        onAlert: @escaping ([(String, Int)]) -> Void
    ) {
        self.minKpa = minKpa
        self.hysteresisKpa = hysteresisKpa
        self.onAlert = onAlert
    }

    public func onTelemetry(_ telemetry: VehicleTelemetry) {
        guard let tires = telemetry.tirePressuresKpa else { return }
        let readings = [("FL", tires.fl), ("FR", tires.fr), ("RL", tires.rl), ("RR", tires.rr)]

        // Re-arm wheels that have climbed back above the hysteresis band.
        for (name, kpa) in readings where alerted.contains(name) && kpa >= minKpa + hysteresisKpa {
            alerted.remove(name)
        }

        let low = readings.filter { $0.1 < minKpa }
        let newlyLow = low.filter { !alerted.contains($0.0) }
        guard !newlyLow.isEmpty else { return }
        newlyLow.forEach { alerted.insert($0.0) }
        // Only the wheels that newly crossed the threshold. Passing `low` here
        // re-alerted already-announced wheels every time another one went low.
        onAlert(newlyLow.map { ($0.0, Int($0.1)) })
    }
}

// MARK: - BatteryHealthEstimator

/// Independent pack-SOH estimate by energy integration (coulomb counting) over a
/// charge session, as a cross-check on the BMS-reported SOH.
///
///     measuredUsableKwh = energyKwh / (ΔSOC / 100)
///     SOH%              = measuredUsableKwh / ratedUsableKwh * 100
///
/// Limits: it uses pack-terminal power, so it over-counts by the I²R charge losses
/// and reads a hair optimistic; it needs one uninterrupted charge over a decent SOC
/// span; and it assumes SOC is linear in energy (close enough over the mid range).
public final class BatteryHealthEstimator {
    private let ratedUsableKwh: Double
    private let minDeltaSoc: Float

    private var accumulating = false
    private var startSoc: Float = 0
    private var energyKwh: Double = 0
    private var lastTimestamp: Date?

    public private(set) var estimatedSohPercent: Float?

    /// - Parameter minDeltaSoc: minimum SOC swing before an estimate is published.
    ///   SOC decodes at 0.5% resolution, so a small span carries more quantisation
    ///   error than the few percent of real degradation this exists to detect — at
    ///   40% that error is around ±1%. Estimates become rarer but mean something.
    public init(ratedUsableKwh: Double, minDeltaSoc: Float = 40) {
        self.ratedUsableKwh = ratedUsableKwh
        self.minDeltaSoc = minDeltaSoc
    }

    @discardableResult
    public func onTelemetry(_ telemetry: VehicleTelemetry) -> Float? {
        guard let soc = telemetry.socDisplay ?? telemetry.socBms else {
            return estimatedSohPercent
        }

        guard telemetry.isCharging, let power = telemetry.powerKw, power > 0 else {
            accumulating = false                    // charge ended or driving resumed
            return estimatedSohPercent
        }

        guard accumulating else {
            accumulating = true
            startSoc = soc
            energyKwh = 0
            lastTimestamp = telemetry.timestamp
            return estimatedSohPercent
        }

        let dtHours = telemetry.timestamp.timeIntervalSince(lastTimestamp ?? telemetry.timestamp) / 3600
        lastTimestamp = telemetry.timestamp
        // Ignore implausible gaps (clock jumps, backgrounded app) so one huge
        // interval can't corrupt the integral.
        if dtHours > 0, dtHours < 10.0 / 3600.0 {
            energyKwh += Double(power) * dtHours
        }

        let deltaSoc = soc - startSoc
        if deltaSoc >= minDeltaSoc, ratedUsableKwh > 0 {
            let measuredUsableKwh = energyKwh / (Double(deltaSoc) / 100)
            let soh = Float(measuredUsableKwh / ratedUsableKwh * 100)
            // Reject physically impossible results (bad frames, SOC glitches).
            if (50...115).contains(soh) { estimatedSohPercent = soh }
        }
        return estimatedSohPercent
    }
}
