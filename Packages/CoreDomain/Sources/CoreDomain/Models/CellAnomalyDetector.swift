import Foundation

/// Detects cell voltage anomalies from telemetry data.
public struct CellAnomalyDetector: Sendable {

    public init() {}

    /// Returns true if the cell voltage delta exceeds safe thresholds.
    public func isAnomalous(telemetry: VehicleTelemetry) -> Bool {
        guard let delta = telemetry.cellVoltDelta else { return false }
        return delta > 50 // mV threshold
    }

    /// Returns a human-readable description of the anomaly, or nil if none.
    public func describe(telemetry: VehicleTelemetry) -> String? {
        guard let delta = telemetry.cellVoltDelta else { return nil }
        if delta > 100 { return "Critical cell imbalance detected (\(String(format: "%.0f", delta)) mV)" }
        if delta > 50 { return "Elevated cell delta (\(String(format: "%.0f", delta)) mV)" }
        return nil
    }
}
