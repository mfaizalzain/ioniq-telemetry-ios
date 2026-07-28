import Foundation
import Testing
@testable import CoreDomain

/// These cover the two regressions the Android build shipped: a deadlock where
/// starting a trip needed GPS while GPS needed an active trip, and a latched speed
/// that left a parked car looking like it was still moving.
struct DriveMonitorTests {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func frame(
        connected: Bool = true,
        charging: Bool = false,
        odometer: Int? = nil,
        fix: Fix? = nil,
        inVehicle: Bool = false,
        location: Bool = true,
        motion: Bool = false,
        at offset: TimeInterval = 0,
        from base: Date? = nil
    ) -> DriveFrame {
        DriveFrame(
            connected: connected,
            rawIsCharging: charging,
            rawChargeType: charging ? .dc : nil,
            odometerKm: odometer,
            fix: fix,
            inVehicle: inVehicle,
            hasLocationPermission: location,
            hasMotionPermission: motion,
            now: (base ?? start).addingTimeInterval(offset)
        )
    }

    @Test("a stationary connected car does not start a trip")
    func stationaryDoesNotStart() {
        let monitor = DriveMonitor()
        let fix = Fix(lat: 3.14, lon: 101.68, at: start)
        for minute in 0..<10 {
            let decision = monitor.onFrame(
                frame(odometer: 1000, fix: fix, at: Double(minute) * 60)
            )
            #expect(decision.transition != .start)
        }
        #expect(!monitor.tripActive)
    }

    @Test("moving away from the anchor starts a trip")
    func movementStartsTrip() {
        let monitor = DriveMonitor()
        let anchor = Fix(lat: 3.1400, lon: 101.6800, at: start)
        _ = monitor.onFrame(frame(fix: anchor))

        // ~110 m north — past both the movement and trip-start thresholds.
        let moved = Fix(lat: 3.1410, lon: 101.6800, at: start.addingTimeInterval(20))
        let decision = monitor.onFrame(frame(fix: moved, at: 20))

        #expect(decision.transition == .start)
        #expect(monitor.tripActive)
    }

    @Test("odometer alone starts a trip when GPS is unavailable")
    func odometerStartsTripWithoutGps() {
        let monitor = DriveMonitor()
        _ = monitor.onFrame(frame(odometer: 1000, fix: nil, location: false))
        let decision = monitor.onFrame(frame(odometer: 1001, fix: nil, location: false, at: 60))
        #expect(decision.transition == .start)
    }

    @Test("a stale fix reports zero speed, not the last road speed")
    func staleFixDoesNotLatchSpeed() {
        let monitor = DriveMonitor()
        let first = Fix(lat: 3.1400, lon: 101.6800, at: start)
        _ = monitor.onFrame(frame(fix: first))

        let second = Fix(lat: 3.1410, lon: 101.6800, at: start.addingTimeInterval(10))
        let moving = monitor.onFrame(frame(fix: second, at: 10))
        #expect((moving.speedKph ?? 0) > 3)

        // Same fix, well past the staleness window, and the odometer never moved.
        let stale = monitor.onFrame(frame(odometer: 1000, fix: second, at: 120))
        #expect(stale.speedKph == 0)
    }

    @Test("a stale fix with a rising odometer reports unknown speed, not zero")
    func tunnelReportsUnknownSpeed() {
        let monitor = DriveMonitor()
        let fix = Fix(lat: 3.14, lon: 101.68, at: start)
        _ = monitor.onFrame(frame(odometer: 1000, fix: fix))
        _ = monitor.onFrame(frame(odometer: 1001, fix: fix, at: 30))

        // Reception lost but the car is still covering ground: nil, never 0 —
        // reporting 0 here would make regen look like charging.
        let decision = monitor.onFrame(frame(odometer: 1002, fix: fix, at: 60))
        #expect(decision.speedKph == nil)
    }

    @Test("regen at a standstill is not reported as charging")
    func regenIsNotCharging() {
        let monitor = DriveMonitor()
        let fix = Fix(lat: 3.14, lon: 101.68, at: start)
        // Positive pack current for 10 s — a braking burst, under the confirm window.
        _ = monitor.onFrame(frame(charging: true, fix: fix))
        let decision = monitor.onFrame(frame(charging: true, fix: fix, at: 10))
        #expect(!decision.isCharging)
    }

    @Test("sustained stationary draw is reported as charging")
    func sustainedDrawIsCharging() {
        let monitor = DriveMonitor()
        let fix = Fix(lat: 3.14, lon: 101.68, at: start)
        _ = monitor.onFrame(frame(charging: true, fix: fix))
        let decision = monitor.onFrame(frame(charging: true, fix: fix, at: 45))
        #expect(decision.isCharging)
        #expect(decision.chargeType == .dc)
    }

    @Test("a long idle ends the trip even while still connected")
    func idleEndsTrip() {
        let monitor = DriveMonitor()
        let anchor = Fix(lat: 3.1400, lon: 101.6800, at: start)
        _ = monitor.onFrame(frame(fix: anchor))
        let moved = Fix(lat: 3.1410, lon: 101.6800, at: start.addingTimeInterval(20))
        #expect(monitor.onFrame(frame(fix: moved, at: 20)).transition == .start)

        let decision = monitor.onFrame(frame(fix: moved, at: 20 + 6 * 60))
        #expect(decision.transition == .end)
        #expect(!monitor.tripActive)
    }

    /// The contract `ConnectedCarService`'s supervisor depends on: park at home,
    /// switch off with the dongle still in, and the bus stops answering. Nothing
    /// advances this monitor until a frame arrives, so the supervisor synthesises
    /// one on wall-clock time — and it must close the trip on arrival rather than
    /// needing a fresh run of live frames.
    @Test("a synthetic frame after a long silence still ends the trip")
    func silentSessionEndsTripOnNextFrame() {
        let monitor = DriveMonitor()
        let anchor = Fix(lat: 3.1400, lon: 101.6800, at: start)
        _ = monitor.onFrame(frame(fix: anchor))
        let moved = Fix(lat: 3.1410, lon: 101.6800, at: start.addingTimeInterval(20))
        #expect(monitor.onFrame(frame(fix: moved, at: 20)).transition == .start)

        // Car asleep for two hours: no frames at all, then the supervisor ticks.
        let decision = monitor.onFrame(frame(fix: moved, at: 20 + 2 * 60 * 60))
        #expect(decision.transition == .end)
        #expect(!monitor.tripActive)
        #expect(!decision.isCharging)
    }

    /// The supervisor passes `rawIsCharging: false` on its synthetic frames, so a
    /// charge that begins while the bus is quiet must be confirmed by real frames
    /// once they resume — never by the ticks themselves.
    @Test("charging still confirms from real frames after a silent spell")
    func chargingConfirmsAfterSilence() {
        let monitor = DriveMonitor()
        let fix = Fix(lat: 3.1400, lon: 101.6800, at: start)
        _ = monitor.onFrame(frame(fix: fix))

        // Supervisor ticks while the car sleeps: never charging.
        for minute in 1...30 {
            let tick = monitor.onFrame(frame(charging: false, fix: fix, at: Double(minute) * 60))
            #expect(!tick.isCharging)
        }

        // Plugged in: real frames resume, stationary with positive pack current.
        let plugIn = start.addingTimeInterval(31 * 60)
        #expect(!monitor.onFrame(frame(charging: true, fix: fix, from: plugIn)).isCharging)
        let confirmed = monitor.onFrame(frame(charging: true, fix: fix, at: 31, from: plugIn))
        #expect(confirmed.isCharging)
        #expect(confirmed.chargeType == .dc)
    }
}
