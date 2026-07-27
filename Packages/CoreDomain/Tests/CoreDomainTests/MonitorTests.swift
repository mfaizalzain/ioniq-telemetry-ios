import Foundation
import Testing
@testable import CoreDomain

struct ParkedStateEvaluatorTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("no adapter means unknown, never moving")
    func disconnectedIsUnknown() {
        let evaluator = ParkedStateEvaluator()
        #expect(evaluator.onFrame(speedKph: 50, connected: false, now: start) == .unknown)
    }

    @Test("becoming driving is instant")
    func drivingIsInstant() {
        let evaluator = ParkedStateEvaluator()
        #expect(evaluator.onFrame(speedKph: 40, connected: true, now: start) == .driving)
    }

    @Test("becoming parked needs the dwell period")
    func parkedNeedsDwell() {
        let evaluator = ParkedStateEvaluator()
        _ = evaluator.onFrame(speedKph: 40, connected: true, now: start)
        // A stop light: stationary but well inside the settle window.
        #expect(evaluator.onFrame(speedKph: 0, connected: true, now: start.addingTimeInterval(5)) == .driving)
        #expect(evaluator.onFrame(speedKph: 0, connected: true, now: start.addingTimeInterval(15)) == .parked)
    }

    @Test("unknown speed holds state instead of accruing dwell")
    func nilSpeedHolds() {
        let evaluator = ParkedStateEvaluator()
        _ = evaluator.onFrame(speedKph: 90, connected: true, now: start)
        // In a tunnel at motorway speed — must not drift to parked.
        for second in stride(from: 5, through: 60, by: 5) {
            let state = evaluator.onFrame(
                speedKph: nil, connected: true, now: start.addingTimeInterval(Double(second))
            )
            #expect(state == .driving)
        }
    }

    @Test("only a confirmed stationary car allows attention-heavy UI")
    func gating() {
        #expect(ParkedState.parked.allowsAttentionHeavyUi)
        #expect(ParkedState.charging.allowsAttentionHeavyUi)
        #expect(!ParkedState.driving.allowsAttentionHeavyUi)
        #expect(!ParkedState.unknown.allowsAttentionHeavyUi)
    }
}

struct ChargeAlertMonitorTests {

    private func telemetry(soc: Float, charging: Bool, speed: Float? = 0) -> VehicleTelemetry {
        VehicleTelemetry(socDisplay: soc, speedKph: speed, isCharging: charging)
    }

    @Test("plugging in above a threshold does not fire it retroactively")
    func noRetroactiveAlert() {
        var fired: [Float] = []
        let monitor = ChargeAlertMonitor { threshold, _ in fired.append(threshold) }
        monitor.onTelemetry(telemetry(soc: 85, charging: true))
        monitor.onTelemetry(telemetry(soc: 86, charging: true))
        #expect(fired.isEmpty)
    }

    @Test("crossing a threshold fires once")
    func crossingFiresOnce() {
        var fired: [Float] = []
        let monitor = ChargeAlertMonitor { threshold, _ in fired.append(threshold) }
        monitor.onTelemetry(telemetry(soc: 70, charging: true))
        monitor.onTelemetry(telemetry(soc: 79, charging: true))
        monitor.onTelemetry(telemetry(soc: 81, charging: true))
        monitor.onTelemetry(telemetry(soc: 83, charging: true))
        #expect(fired == [80])
    }

    @Test("regen while moving never alerts")
    func regenIgnored() {
        var fired: [Float] = []
        let monitor = ChargeAlertMonitor { threshold, _ in fired.append(threshold) }
        monitor.onTelemetry(telemetry(soc: 70, charging: true, speed: 60))
        monitor.onTelemetry(telemetry(soc: 85, charging: true, speed: 60))
        #expect(fired.isEmpty)
    }

    @Test("a new session re-arms the thresholds")
    func newSessionReArms() {
        var fired: [Float] = []
        let monitor = ChargeAlertMonitor { threshold, _ in fired.append(threshold) }
        monitor.onTelemetry(telemetry(soc: 70, charging: true))
        monitor.onTelemetry(telemetry(soc: 81, charging: true))
        monitor.onTelemetry(telemetry(soc: 81, charging: false))   // unplugged
        monitor.onTelemetry(telemetry(soc: 60, charging: true))    // new session
        monitor.onTelemetry(telemetry(soc: 82, charging: true))
        #expect(fired == [80, 80])
    }
}

struct TirePressureMonitorTests {

    private func telemetry(_ fl: Float, _ fr: Float, _ rl: Float, _ rr: Float) -> VehicleTelemetry {
        VehicleTelemetry(tirePressuresKpa: TirePressures(fl: fl, fr: fr, rl: rl, rr: rr))
    }

    @Test("a low wheel alerts once, not on every frame")
    func alertsOnce() {
        var alerts = 0
        let monitor = TirePressureMonitor { _ in alerts += 1 }
        for _ in 0..<5 {
            monitor.onTelemetry(telemetry(200, 240, 240, 240))
        }
        #expect(alerts == 1)
    }

    @Test("a wheel hovering at the threshold does not re-alert")
    func hysteresis() {
        var alerts = 0
        let monitor = TirePressureMonitor { _ in alerts += 1 }
        monitor.onTelemetry(telemetry(219, 240, 240, 240))
        monitor.onTelemetry(telemetry(222, 240, 240, 240))   // recovered, but inside the band
        monitor.onTelemetry(telemetry(219, 240, 240, 240))
        #expect(alerts == 1)

        monitor.onTelemetry(telemetry(235, 240, 240, 240))   // clear of the band: re-armed
        monitor.onTelemetry(telemetry(210, 240, 240, 240))
        #expect(alerts == 2)
    }
}

struct BatteryHealthEstimatorTests {

    @Test("no estimate before the minimum SOC swing")
    func needsBigSwing() {
        let estimator = BatteryHealthEstimator(ratedUsableKwh: 74)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for step in 0..<20 {
            let sample = VehicleTelemetry(
                timestamp: base.addingTimeInterval(Double(step) * 5),
                socDisplay: 20 + Float(step) * 0.5,
                powerKw: 50,
                isCharging: true
            )
            #expect(estimator.onTelemetry(sample) == nil)
        }
    }

    @Test("a full charge over a wide swing produces a plausible estimate")
    func producesEstimate() {
        let rated = 74.0
        let estimator = BatteryHealthEstimator(ratedUsableKwh: rated)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let powerKw: Float = 50
        // 5-second steps; SOC advances at exactly the rate 50 kW implies for a
        // healthy 74 kWh pack, so the estimate should land near 100%.
        let socPerStep = Float(Double(powerKw) * (5.0 / 3600.0) / rated * 100)

        var soc: Float = 10
        var step = 0
        var result: Float?
        while soc < 95 {
            let sample = VehicleTelemetry(
                timestamp: base.addingTimeInterval(Double(step) * 5),
                socDisplay: soc,
                powerKw: powerKw,
                isCharging: true
            )
            result = estimator.onTelemetry(sample)
            soc += socPerStep
            step += 1
        }
        let estimate = try? #require(result)
        #expect((estimate ?? 0) > 90 && (estimate ?? 0) < 110)
    }
}
