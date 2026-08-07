import Foundation

/// A position sample. Deliberately not `CLLocation`: the whole point of this type
/// is that the motion logic can be exercised without a CoreLocation runtime.
public struct Fix: Sendable, Equatable {
    public let lat: Double
    public let lon: Double
    public let at: Date

    public init(lat: Double, lon: Double, at: Date) {
        self.lat = lat
        self.lon = lon
        self.at = at
    }

    /// Great-circle distance in metres.
    public func distance(to other: Fix) -> Double {
        let earthRadiusM = 6_371_000.0
        let dLat = (other.lat - lat) * .pi / 180
        let dLon = (other.lon - lon) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat * .pi / 180) * cos(other.lat * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return earthRadiusM * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}

/// Everything the monitor needs about one telemetry frame.
public struct DriveFrame: Sendable {
    public let connected: Bool
    public let rawIsCharging: Bool
    public let rawChargeType: ChargeType?
    public let odometerKm: Int?
    public let fix: Fix?
    public let inVehicle: Bool
    public let hasLocationPermission: Bool
    public let hasMotionPermission: Bool
    public let now: Date

    public init(
        connected: Bool,
        rawIsCharging: Bool,
        rawChargeType: ChargeType? = nil,
        odometerKm: Int? = nil,
        fix: Fix? = nil,
        inVehicle: Bool = false,
        hasLocationPermission: Bool = false,
        hasMotionPermission: Bool = false,
        now: Date = Date()
    ) {
        self.connected = connected
        self.rawIsCharging = rawIsCharging
        self.rawChargeType = rawChargeType
        self.odometerKm = odometerKm
        self.fix = fix
        self.inVehicle = inVehicle
        self.hasLocationPermission = hasLocationPermission
        self.hasMotionPermission = hasMotionPermission
        self.now = now
    }
}

public enum TripTransition: Sendable, Equatable {
    case none, start, end
}

/// Corrected view of the frame plus any trip boundary it implies.
///
/// `isCharging` and `chargeType` are corrected values: the decoder reports "pack
/// current is positive", which is equally true of regen — only road speed and
/// duration distinguish the two.
public struct DriveDecision: Sendable, Equatable {
    public let speedKph: Float?
    public let isCharging: Bool
    public let chargeType: ChargeType?
    public let transition: TripTransition
    public let tripActive: Bool
}

/// Trip and motion state machine.
///
/// Kept as a plain object with no platform dependencies: motion logic that can
/// only be exercised by actually driving is motion logic that ships broken. Feed
/// it one `DriveFrame` per telemetry emission and act on the `DriveDecision`.
///
/// Not thread-safe; drive it from a single consumer.
///
/// Ported from Android DriveMonitor.kt.
public final class DriveMonitor {

    // MARK: - Tuning

    /// Movement from the connection point before a drive counts as a trip.
    public static let tripStartMoveM: Double = 60
    /// Grace period before ending an active trip on OBD disconnect.
    public static let tripDisconnectGrace: TimeInterval = 90
    /// Stationary spell that closes a trip even while still connected.
    public static let tripIdleEnd: TimeInterval = 5 * 60
    /// GPS displacement counting as movement. Below `tripStartMoveM` by design.
    public static let movementDistanceM: Double = 50
    /// Above this, the car is driving rather than stationary.
    public static let movementSpeedKph: Float = 3
    /// No fix for this long, at a 25 m filter, means under 25 m covered.
    public static let staleFix: TimeInterval = 30
    /// No E-GMP car exceeds this; a computed figure above it is GPS jitter, not motion.
    public static let maxPlausibleKph: Float = 250
    /// Last-resort trip start when nothing can observe movement.
    public static let blindStartAfter: TimeInterval = 30

    /// How long an odometer increment keeps counting as "still moving". The
    /// odometer is whole kilometres, so at a crawl one tick can be minutes apart.
    public static let odometerMoving: TimeInterval = 3 * 60

    /// How long stationary positive pack current must persist before it counts as
    /// charging rather than regen. This car regenerates to a standstill, so the two
    /// are identical on any single frame; only duration separates them.
    public static let chargeConfirm: TimeInterval = 30

    // MARK: - State

    public private(set) var tripActive = false

    private var tripAnchor: Fix?
    private var connectedSince: Date?
    private var disconnectStart: Date?

    // Three independent motion signals, so a missing permission or an unanswered
    // PID cannot strand the car in a permanently "moving" state.
    private var lastMovementAt: Date?
    private var lastMovementFix: Fix?
    private var lastMovementOdometer: Int?
    private var movementEvents = 0
    /// When the vehicle's own odometer last advanced — motion proof needing no GPS.
    private var lastOdometerIncrementAt: Date?

    private var previousFix: Fix?
    private var lastSpeedKph: Float?

    /// When stationary positive pack current began — see the charging debounce.
    private var chargingSince: Date?

    public init() {}

    // MARK: - Frame

    public func onFrame(_ frame: DriveFrame) -> DriveDecision {
        // Movement first: the odometer decides whether a stale GPS fix means
        // "parked" or merely "no signal", and the speed calculation depends on it.
        updateMovement(frame)
        let odometerMoving = lastOdometerIncrementAt.map {
            frame.now.timeIntervalSince($0) < Self.odometerMoving
        } ?? false

        let speed = updateSpeed(frame, odometerMoving: odometerMoving)
        let moving = (speed ?? 0) > Self.movementSpeedKph || odometerMoving

        if frame.connected {
            disconnectStart = nil
            if tripAnchor == nil, let fix = frame.fix { tripAnchor = fix }
            if connectedSince == nil { connectedSince = frame.now }
        } else if tripActive, disconnectStart == nil {
            disconnectStart = frame.now
        }

        var transition = TripTransition.none
        if !tripActive, frame.connected, shouldStart(frame) {
            tripActive = true
            disconnectStart = nil
            lastMovementAt = frame.now
            movementEvents = 0
            transition = .start
        } else if tripActive, shouldEnd(frame) {
            tripActive = false
            disconnectStart = nil
            // Re-arm: the next trip must be triggered by fresh movement, not state
            // left over from this one. Otherwise a stationary car at a charger
            // restarts a trip the moment the idle end fires.
            tripAnchor = frame.fix
            connectedSince = nil
            lastMovementAt = nil
            movementEvents = 0
            transition = .end
        }

        // Stationary and drawing current is necessary but not sufficient: braking to
        // a halt produces strong positive pack current under 3 km/h. Requiring it to
        // persist separates regen bursts (seconds) from a real charge (minutes).
        let stationaryDraw = frame.rawIsCharging && !moving
        if stationaryDraw {
            if chargingSince == nil { chargingSince = frame.now }
        } else {
            chargingSince = nil
        }
        let charging = chargingSince.map {
            frame.now.timeIntervalSince($0) >= Self.chargeConfirm
        } ?? false

        return DriveDecision(
            speedKph: speed,
            isCharging: charging,
            chargeType: charging ? frame.rawChargeType : nil,
            transition: transition,
            tripActive: tripActive
        )
    }

    public func reset() {
        tripActive = false
        tripAnchor = nil
        connectedSince = nil
        disconnectStart = nil
        lastMovementAt = nil
        lastMovementFix = nil
        lastMovementOdometer = nil
        movementEvents = 0
        lastOdometerIncrementAt = nil
        previousFix = nil
        lastSpeedKph = nil
        chargingSince = nil
    }

    // MARK: - Speed

    /// Speed from consecutive fixes.
    ///
    /// With a displacement filter a parked car produces no new fixes, so carrying
    /// the last value forward would leave a parked car reporting its final road
    /// speed forever — and charging, which requires stationary, would never be
    /// detected. But a stale fix alone doesn't mean stationary: a tunnel kills
    /// reception while the car still moves. When the odometer says the car is
    /// covering ground, speed is unknown (nil) rather than zero — claiming zero
    /// there would make regen look like charging.
    private func updateSpeed(_ frame: DriveFrame, odometerMoving: Bool) -> Float? {
        guard let fix = frame.fix else {
            if odometerMoving { return nil }
            return previousFix != nil ? 0 : nil
        }

        guard let previous = previousFix else {
            previousFix = fix
            lastSpeedKph = 0
            return 0
        }

        if fix.at != previous.at {
            let dtSeconds = fix.at.timeIntervalSince(previous.at)
            if dtSeconds > 0 {
                let kph = Float(previous.distance(to: fix) / dtSeconds * 3.6)
                // Two near-simultaneous fixes with a few metres of GPS jitter can
                // compute to hundreds of km/h — enough to flip a parked car to
                // `.driving` for the whole stale window. Cap at a figure no E-GMP
                // car can reach so jitter reads as a plausible-but-high speed, not
                // as motion evidence.
                let clamped = min(kph, Self.maxPlausibleKph)
                lastSpeedKph = (clamped.isFinite && clamped >= 0) ? clamped : 0
            }
            previousFix = fix
            return lastSpeedKph
        }

        // Same fix as last frame. Past the staleness window it means either the car
        // covered less than the filter threshold (parked) or reception was lost
        // (tunnel) — the odometer separates the two.
        if frame.now.timeIntervalSince(fix.at) <= Self.staleFix { return lastSpeedKph }
        return odometerMoving ? nil : 0
    }

    // MARK: - Movement

    private func updateMovement(_ frame: DriveFrame) {
        var moved = false

        // Deliberately not using speed: it derives from fixes, and the odometer is
        // the one signal that keeps working where GPS does not.
        if let odometer = frame.odometerKm {
            if let previous = lastMovementOdometer {
                if odometer > previous {
                    lastMovementOdometer = odometer
                    lastOdometerIncrementAt = frame.now
                    moved = true
                }
            } else {
                lastMovementOdometer = odometer
                if lastMovementAt == nil { lastMovementAt = frame.now }
            }
        }

        if let fix = frame.fix {
            if let previous = lastMovementFix {
                if previous.distance(to: fix) >= Self.movementDistanceM {
                    lastMovementFix = fix
                    moved = true
                }
            } else {
                lastMovementFix = fix
                if lastMovementAt == nil { lastMovementAt = frame.now }
            }
        }

        if moved {
            lastMovementAt = frame.now
            movementEvents += 1
        }
    }

    // MARK: - Transitions

    private func shouldStart(_ frame: DriveFrame) -> Bool {
        let gpsDriving: Bool = {
            guard frame.hasLocationPermission,
                  let fix = frame.fix,
                  let anchor = tripAnchor else { return false }
            return anchor.distance(to: fix) >= Self.tripStartMoveM
        }()

        // Proven physical movement, from either independent source.
        if gpsDriving || movementEvents > 0 { return true }

        // Something can observe movement, so wait for it rather than guessing. This
        // keeps a stationary car at a charger from restarting a trip every few
        // minutes.
        let blind = !frame.hasLocationPermission && lastMovementOdometer == nil
        guard blind else { return false }

        // Nothing can see movement at all. Only now is a timer justified.
        if frame.hasMotionPermission { return frame.inVehicle }
        guard let connectedSince else { return false }
        return frame.now.timeIntervalSince(connectedSince) > Self.blindStartAfter
    }

    private func shouldEnd(_ frame: DriveFrame) -> Bool {
        let sinceDisconnect = disconnectStart.map { frame.now.timeIntervalSince($0) }

        let graceExpired = (sinceDisconnect ?? 0) >= Self.tripDisconnectGrace
            && disconnectStart != nil
        let motionEnded = frame.hasMotionPermission && !frame.inVehicle && !frame.connected
            && (sinceDisconnect ?? 0) >= 30 && disconnectStart != nil
        // Stationary long enough to call it a stop, splitting a journey at charge
        // stops. Requires a movement signal to have been seen at all, so a setup
        // with no usable signal keeps disconnect-only behaviour.
        let idleEnded = lastMovementAt.map {
            frame.now.timeIntervalSince($0) >= Self.tripIdleEnd
        } ?? false

        return graceExpired || motionEnded || idleEnded
    }
}
