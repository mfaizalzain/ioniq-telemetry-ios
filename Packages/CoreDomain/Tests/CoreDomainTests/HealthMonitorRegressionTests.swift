import Foundation
import Testing
@testable import CoreDomain

struct ThermalAdvisorRegressionTests {

    @Test("freezing message can fire (order bug)")
    func freezingBranchReachable() {
        let advisor = ThermalAdvisor()
        let freezing = advisor.evaluate(telemetry: VehicleTelemetry(moduleTempsC: [-5]))
        #expect(freezing?.contains("freezing") == true)

        let cold = advisor.evaluate(telemetry: VehicleTelemetry(moduleTempsC: [5]))
        #expect(cold?.contains("cold") == true)

        let hot = advisor.evaluate(telemetry: VehicleTelemetry(moduleTempsC: [50]))
        #expect(hot?.contains("high") == true)
    }

    @Test("no temperature data returns nil")
    func noDataIsNil() {
        #expect(ThermalAdvisor().evaluate(telemetry: VehicleTelemetry()) == nil)
    }
}

struct TirePressureMonitorRegressionTests {

    private func telemetry(tires: TirePressures) -> VehicleTelemetry {
        VehicleTelemetry(tirePressuresKpa: tires)
    }

    @Test("second wheel going low does not re-alert the first")
    func noRealert() async {
        var alerts: [[(String, Int)]] = []
        let monitor = TirePressureMonitor { alerts.append($0) }

        monitor.onTelemetry(telemetry(tires: TirePressures(fl: 200, fr: 240, rl: 240, rr: 240)))
        monitor.onTelemetry(telemetry(tires: TirePressures(fl: 200, fr: 210, rl: 240, rr: 240)))

        #expect(alerts.count == 2)
        #expect(alerts[1].count == 1)
        #expect(alerts[1][0].0 == "FR")
    }

    @Test("wheel re-arms only above the hysteresis band")
    func hysteresis() {
        var alerts: [[(String, Int)]] = []
        let monitor = TirePressureMonitor { alerts.append($0) }

        monitor.onTelemetry(telemetry(tires: TirePressures(fl: 200, fr: 240, rl: 240, rr: 240)))
        // Partial recovery: still inside 220..230 hysteresis — must not re-alert.
        monitor.onTelemetry(telemetry(tires: TirePressures(fl: 215, fr: 240, rl: 240, rr: 240)))
        #expect(alerts.count == 1)

        monitor.onTelemetry(telemetry(tires: TirePressures(fl: 240, fr: 240, rl: 240, rr: 240)))
        monitor.onTelemetry(telemetry(tires: TirePressures(fl: 190, fr: 240, rl: 240, rr: 240)))
        #expect(alerts.count == 2)
    }
}

struct DriveMonitorSpeedCapTests {

    private func frame(fix: Fix, connected: Bool = true) -> DriveFrame {
        DriveFrame(connected: connected, rawIsCharging: false, fix: fix, now: fix.at)
    }

    @Test("near-simultaneous jitter fixes are capped, not read as high speed")
    func speedCapped() {
        let monitor = DriveMonitor()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let start = Fix(lat: 0.0, lon: 0.0, at: t0)
        // ~33 m of jitter in 0.1 s computes to ~1200 km/h — physically impossible,
        // so it must clamp to the plausible ceiling rather than flip the car to
        // .driving on pure GPS noise.
        let jitter = Fix(lat: 0.0003, lon: 0.0, at: t0.addingTimeInterval(0.1))

        _ = monitor.onFrame(frame(fix: start))
        let decision = monitor.onFrame(frame(fix: jitter))

        #expect(decision.speedKph != nil)
        #expect(decision.speedKph! <= DriveMonitor.maxPlausibleKph)
    }

    @Test("a genuinely fast fix still passes through")
    func realSpeedUncapped() {
        let monitor = DriveMonitor()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let start = Fix(lat: 0.0, lon: 0.0, at: t0)
        // ~50 km in 15 minutes = 200 km/h, plausible, must not be clamped.
        let fast = Fix(lat: 0.45, lon: 0.0, at: t0.addingTimeInterval(15 * 60))

        _ = monitor.onFrame(frame(fix: start))
        let decision = monitor.onFrame(frame(fix: fast))

        #expect(decision.speedKph != nil)
        #expect(decision.speedKph! > 150)
    }
}
