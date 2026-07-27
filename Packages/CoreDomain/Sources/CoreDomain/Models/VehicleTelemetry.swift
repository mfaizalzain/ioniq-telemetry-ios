import Foundation

// MARK: - VehicleTelemetry

public struct VehicleTelemetry: Sendable, Equatable {
    public var timestamp: Date
    public var socBms: Float?
    public var socDisplay: Float?
    public var soh: Float?
    public var packVoltage: Float?
    public var packCurrent: Float?
    public var powerKw: Float?
    public var cellVoltMin: Float?
    public var cellVoltMax: Float?
    public var cellVoltDelta: Float?
    public var moduleTempsC: [Int]
    public var inletTempC: Int?
    public var ambientTempC: Int?
    public var cabinTempC: Int?
    public var setTempC: Float?
    public var speedKph: Float?
    public var odometerKm: Int?
    public var auxVoltage: Float?
    public var tirePressuresKpa: TirePressures?
    public var tireTempsC: TireTemperatures?
    public var isCharging: Bool
    public var chargeType: ChargeType?
    public var connectionState: ObdConnectionState

    public init(
        timestamp: Date = Date(),
        socBms: Float? = nil,
        socDisplay: Float? = nil,
        soh: Float? = nil,
        packVoltage: Float? = nil,
        packCurrent: Float? = nil,
        powerKw: Float? = nil,
        cellVoltMin: Float? = nil,
        cellVoltMax: Float? = nil,
        cellVoltDelta: Float? = nil,
        moduleTempsC: [Int] = [],
        inletTempC: Int? = nil,
        ambientTempC: Int? = nil,
        cabinTempC: Int? = nil,
        setTempC: Float? = nil,
        speedKph: Float? = nil,
        odometerKm: Int? = nil,
        auxVoltage: Float? = nil,
        tirePressuresKpa: TirePressures? = nil,
        tireTempsC: TireTemperatures? = nil,
        isCharging: Bool = false,
        chargeType: ChargeType? = nil,
        connectionState: ObdConnectionState = .disconnected
    ) {
        self.timestamp = timestamp
        self.socBms = socBms
        self.socDisplay = socDisplay
        self.soh = soh
        self.packVoltage = packVoltage
        self.packCurrent = packCurrent
        self.powerKw = powerKw
        self.cellVoltMin = cellVoltMin
        self.cellVoltMax = cellVoltMax
        self.cellVoltDelta = cellVoltDelta
        self.moduleTempsC = moduleTempsC
        self.inletTempC = inletTempC
        self.ambientTempC = ambientTempC
        self.cabinTempC = cabinTempC
        self.setTempC = setTempC
        self.speedKph = speedKph
        self.odometerKm = odometerKm
        self.auxVoltage = auxVoltage
        self.tirePressuresKpa = tirePressuresKpa
        self.tireTempsC = tireTempsC
        self.isCharging = isCharging
        self.chargeType = chargeType
        self.connectionState = connectionState
    }
}

// MARK: - Tire Data

public struct TirePressures: Sendable, Equatable {
    public var fl: Float
    public var fr: Float
    public var rl: Float
    public var rr: Float

    public init(fl: Float, fr: Float, rl: Float, rr: Float) {
        self.fl = fl
        self.fr = fr
        self.rl = rl
        self.rr = rr
    }
}

public struct TireTemperatures: Sendable, Equatable {
    public var fl: Float
    public var fr: Float
    public var rl: Float
    public var rr: Float

    public init(fl: Float, fr: Float, rl: Float, rr: Float) {
        self.fl = fl
        self.fr = fr
        self.rl = rl
        self.rr = rr
    }
}

// MARK: - Enums

public enum ChargeType: String, Sendable, CaseIterable {
    case ac = "AC"
    case dc = "DC"
    case none = "NONE"
}

public enum ObdConnectionState: String, Sendable, CaseIterable {
    case disconnected = "DISCONNECTED"
    case scanning = "SCANNING"
    case connecting = "CONNECTING"
    case initializing = "INITIALIZING"
    case connected = "CONNECTED"
    case error = "ERROR"
}
