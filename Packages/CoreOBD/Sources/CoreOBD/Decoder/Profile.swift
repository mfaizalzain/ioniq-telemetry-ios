import Foundation

// MARK: - Poll Tier

public enum PollTier: String, Codable, Sendable {
    case FAST
    case MEDIUM
    case SLOW

    public var intervalMs: Int64 {
        switch self {
        case .FAST: return 1_000
        case .MEDIUM: return 5_000
        case .SLOW: return 60_000
        }
    }

    public var priority: Int {
        switch self {
        case .FAST: return 0
        case .MEDIUM: return 1
        case .SLOW: return 2
        }
    }
}

// MARK: - Signal Definition

public struct SignalDef: Codable, Sendable, Equatable {
    public let id: String
    public let startByte: Int
    public let length: Int
    public let formula: String
    public let unit: String
    public let signed: Bool
    public let min: Double?
    public let max: Double?

    public init(
        id: String,
        startByte: Int,
        length: Int,
        formula: String,
        unit: String,
        signed: Bool = false,
        min: Double? = nil,
        max: Double? = nil
    ) {
        self.id = id
        self.startByte = startByte
        self.length = length
        self.formula = formula
        self.unit = unit
        self.signed = signed
        self.min = min
        self.max = max
    }
}

// MARK: - Request Definition

public struct RequestDef: Codable, Sendable, Identifiable {
    public let id: String
    public let header: String
    public let request: String
    public let pollTier: PollTier
    public let signals: [SignalDef]
}

// MARK: - Decoder Profile

public struct DecoderProfile: Codable, Sendable {
    public let profileId: String
    public let displayName: String
    public let usableCapacityKwh: Double
    public let requests: [RequestDef]
}

// MARK: - Profile Parser

public enum ProfileParser {
    public static func parse(json: String) throws -> DecoderProfile {
        guard let data = json.data(using: .utf8) else {
            throw ProfileError.invalidJSON
        }
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(DecoderProfile.self, from: data)
        } catch {
            throw ProfileError.decodingFailed(error)
        }
    }

    public static func parse(data: Data) throws -> DecoderProfile {
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(DecoderProfile.self, from: data)
        } catch {
            throw ProfileError.decodingFailed(error)
        }
    }
}

public enum ProfileError: Error {
    case invalidJSON
    case decodingFailed(Error)
}
