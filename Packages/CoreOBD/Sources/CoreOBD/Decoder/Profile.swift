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

    /// `signed` is absent from most entries in the profile JSON — unsigned is the
    /// common case — so it decodes with a default rather than failing the profile.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        startByte = try container.decode(Int.self, forKey: .startByte)
        length = try container.decode(Int.self, forKey: .length)
        formula = try container.decode(String.self, forKey: .formula)
        unit = try container.decode(String.self, forKey: .unit)
        signed = try container.decodeIfPresent(Bool.self, forKey: .signed) ?? false
        min = try container.decodeIfPresent(Double.self, forKey: .min)
        max = try container.decodeIfPresent(Double.self, forKey: .max)
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
    /// The bundle holding the packaged profile JSONs. `Bundle.module` resolves
    /// per-target, so tests must reach the profiles through this rather than
    /// their own (resource-less) bundle.
    public static let resourceBundle = Bundle.module

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

public enum ProfileError: LocalizedError {
    case invalidJSON
    case decodingFailed(any Error)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON: return "Profile is not valid JSON."
        case .decodingFailed(let underlying): return String(describing: underlying)
        }
    }
}
