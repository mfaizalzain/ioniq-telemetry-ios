import CoreDomain
import Foundation

/// Feeds fake telemetry + GPS through the ConnectedCarService pipeline so trip
/// distance can be tested without driving. Wire in via AppServices.initialize().
@MainActor
final class DebugSimulator {

    /// Simulated drive: 10 km north at ~50 km/h, telemetry at 1 Hz.
    private static let driveDistanceKm: Double = 10.0
    private static let speedMs: Double = 13.9  // ~50 km/h
    private static let tickInterval: TimeInterval = 1.0
    private static let startLat: Double = 3.1390   // KL
    private static let startLon: Double = 101.6869

    private var isRunning = false

    /// Called each tick with a telemetry frame and GPS fix that the caller feeds
    /// into their consume() pipeline.
    func start(onTick: @escaping @MainActor (VehicleTelemetry, Fix) -> Void) {
        guard !isRunning else { return }
        isRunning = true

        let totalTicks = Int(Self.driveDistanceKm * 1000 / Self.speedMs / Self.tickInterval)
        let latPerTick = (Self.driveDistanceKm / 111_320.0) / Double(totalTicks) // degrees per metre

        Task {
            var tick = 0
            var socBms: Float = 72.0
            var socDisplay: Float = 72.0
            let packVoltage: Float = 355.0

            while tick < totalTicks && isRunning {
                let lat = Self.startLat + latPerTick * Double(tick)
                let lon = Self.startLon

                // Simulate power: alternating acceleration, cruise, regen
                let power: Float
                switch tick % 10 {
                case 0...2:  power = -45   // acceleration
                case 3...5:  power = -15   // cruise
                case 6...7:  power = 8     // light regen
                case 8...9:  power = 25    // strong regen
                default:     power = 0
                }

                let current = -power / packVoltage * 1000
                let speedKph = Float(Self.speedMs * 3.6)

                // SOC drops ~0.005% per tick
                socBms -= 0.005
                socDisplay = socBms + 0.5

                let telemetry = VehicleTelemetry(
                    timestamp: Date(),
                    socBms: socBms,
                    socDisplay: socDisplay,
                    soh: 98.5,
                    packVoltage: packVoltage,
                    packCurrent: current,
                    powerKw: power,
                    cellVoltMin: 3.62,
                    cellVoltMax: 3.65,
                    cellVoltDelta: 0.03,
                    moduleTempsC: [28, 29],
                    ambientTempC: 30,
                    speedKph: speedKph,
                    odometerKm: 15000 + Int(Double(tick) * Self.speedMs * Self.tickInterval / 1000),
                    auxVoltage: 13.2,
                    tirePressuresKpa: TirePressures(fl: 250, fr: 248, rl: 252, rr: 249),
                    tireTempsC: TireTemperatures(fl: 32, fr: 33, rl: 31, rr: 32),
                    isCharging: false,
                    chargeType: .none,
                    connectionState: .connected
                )

                let fix = Fix(lat: lat, lon: lon, at: Date())
                onTick(telemetry, fix)

                tick += 1
                try? await Task.sleep(nanoseconds: UInt64(Self.tickInterval * 1_000_000_000))
            }

            print("[DebugSimulator] finished — \(totalTicks) ticks, ~\(Self.driveDistanceKm) km")
        }
    }

    func stop() {
        isRunning = false
    }
}
