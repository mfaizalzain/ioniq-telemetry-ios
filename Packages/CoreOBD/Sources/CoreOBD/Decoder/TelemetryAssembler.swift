import Foundation
import CoreDomain

/// Folds decoded signal maps into the running VehicleTelemetry snapshot.
public final class TelemetryAssembler {

    public func merge(current: VehicleTelemetry, signals: [String: Double], now: Date) -> VehicleTelemetry {
        var t = current
        t.timestamp = now
        t.connectionState = .connected

        if let v = signals["soc_bms"] { t.socBms = Float(v) }
        if let v = signals["soc_display"] { t.socDisplay = Float(v) }
        if let v = signals["soh"] { t.soh = Float(v) }
        if let v = signals["pack_voltage"] { t.packVoltage = Float(v) }
        if let v = signals["pack_current"] { t.packCurrent = Float(v) }
        if let v = signals["cell_volt_max"] { t.cellVoltMax = Float(v) }
        if let v = signals["cell_volt_min"] { t.cellVoltMin = Float(v) }
        if let v = signals["aux_voltage"] { t.auxVoltage = Float(v) }
        if let v = signals["speed_kph"] { t.speedKph = Float(v) }
        if let v = signals["ambient_temp"] { t.ambientTempC = Int(v) }
        if let v = signals["cabin_temp"] { t.cabinTempC = Int(v) }
        if let v = signals["set_temp"] { t.setTempC = Float(v) }
        if let v = signals["inlet_temp"] { t.inletTempC = Int(v) }
        if let v = signals["odometer_km"] { t.odometerKm = Int(v) }

        if let tempMax = signals["temp_max"]?.intValue, let tempMin = signals["temp_min"]?.intValue {
            t.moduleTempsC = [tempMin, tempMax]
        }

        if let v = t.packVoltage, let i = t.packCurrent {
            t.powerKw = v * i / 1000.0
        }

        if let cMax = t.cellVoltMax, let cMin = t.cellVoltMin {
            t.cellVoltDelta = cMax - cMin
        }

        if let fl = signals["tire_fl"], let fr = signals["tire_fr"],
           let rl = signals["tire_rl"], let rr = signals["tire_rr"] {
            t.tirePressuresKpa = TirePressures(
                fl: Float(fl), fr: Float(fr), rl: Float(rl), rr: Float(rr)
            )
        }

        if let tfl = signals["tire_fl_temp"], let tfr = signals["tire_fr_temp"],
           let trl = signals["tire_rl_temp"], let trr = signals["tire_rr_temp"] {
            t.tireTempsC = TireTemperatures(
                fl: Float(tfl), fr: Float(tfr), rl: Float(trl), rr: Float(trr)
            )
        }

        if let current = t.packCurrent {
            let charging = current > 1.0
            t.isCharging = charging
            if !charging {
                t.chargeType = ChargeType.none
            } else if current > 60.0 {
                t.chargeType = .dc
            } else {
                t.chargeType = .ac
            }
        }

        return t
    }
}

private extension Double {
    var intValue: Int { Int(self) }
}
