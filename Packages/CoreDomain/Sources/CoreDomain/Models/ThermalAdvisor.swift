import Foundation

/// Provides thermal tips based on battery temperatures.
public struct ThermalAdvisor: Sendable {

    public init() {}

    /// Returns a thermal tip if noteworthy, otherwise nil.
    public func evaluate(telemetry: VehicleTelemetry) -> String? {
        guard let temps = telemetry.moduleTempsC as [Int]?, !temps.isEmpty else { return nil }
        let maxTemp = temps.max() ?? 0
        let minTemp = temps.min() ?? 0

        if maxTemp > 45 { return "Battery temperature high (\(maxTemp)°C). Performance may be limited." }
        if minTemp < 10 { return "Battery is cold (\(minTemp)°C). Range and charging speed reduced." }
        if minTemp < 0 { return "Battery is freezing (\(minTemp)°C). Precondition before driving." }
        return nil
    }
}
