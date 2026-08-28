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
        return try parse(data: data)
    }

    public static func parse(data: Data) throws -> DecoderProfile {
        let decoder = JSONDecoder()
        let profile: DecoderProfile
        do {
            profile = try decoder.decode(DecoderProfile.self, from: data)
        } catch {
            throw ProfileError.decodingFailed(error)
        }
        try validate(profile)
        return profile
    }

    /// Fail a malformed profile at parse time instead of at every decode.
    ///
    /// Without this, a single bad entry surfaces far from its cause: a formula
    /// NSExpression can't parse makes `DecoderEngine.evaluateFormula` throw an
    /// Objective-C exception (a crash, not a Swift error) for every decode of
    /// that signal, and a formula referencing more bytes than `length` declares
    /// reads past the declared window (L1–L3 of the 2026-08 review). All five
    /// bundled profiles pass this today; it exists to catch future typos.
    static func validate(_ profile: DecoderProfile) throws {
        guard !profile.profileId.isEmpty else {
            throw ProfileError.invalidProfile("profileId is empty")
        }
        guard profile.usableCapacityKwh > 0, profile.usableCapacityKwh < 250 else {
            throw ProfileError.invalidProfile(
                "usableCapacityKwh out of range: \(profile.usableCapacityKwh)")
        }
        guard !profile.requests.isEmpty else {
            throw ProfileError.invalidProfile("profile has no requests")
        }
        for request in profile.requests {
            guard !request.signals.isEmpty else {
                throw ProfileError.invalidProfile("request \(request.id) has no signals")
            }
            for signal in request.signals {
                try validateSignal(signal, requestId: request.id)
            }
        }
    }

    private static func validateSignal(_ signal: SignalDef, requestId: String) throws {
        let where_ = "request \(requestId), signal \(signal.id)"
        // UDS responses run tens of bytes (the E-GMP BMS module answers with 60+);
        // 255 is a generous sanity ceiling, not a protocol limit. Decode-time reads
        // are bounded by the actual payload length regardless.
        guard signal.length >= 1, signal.length <= 8, signal.startByte >= 0,
              signal.startByte + signal.length <= 255 else {
            throw ProfileError.invalidProfile(
                "\(where_): bad startByte/length (\(signal.startByte)+\(signal.length))")
        }
        guard signal.min == nil || signal.max == nil || signal.min! <= signal.max! else {
            throw ProfileError.invalidProfile("\(where_): min > max")
        }
        // The formula must reference only bytes inside the declared window, and
        // NSExpression must be able to parse it once the byte placeholders are
        // substituted — both checked here, with synthetic bytes standing in for
        // real ones.
        let byteCount = signal.startByte + signal.length
        let bytes = [UInt8](repeating: 0x01, count: byteCount)
        guard DecoderEngine.staticSelfTest(payload: Data(bytes), signal: signal) != nil else {
            throw ProfileError.invalidProfile(
                "\(where_): formula '\(signal.formula)' failed self-test")
        }
    }
}

public enum ProfileError: LocalizedError {
    case invalidJSON
    case decodingFailed(any Error)
    case invalidProfile(String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON: return "Profile is not valid JSON."
        case .decodingFailed(let underlying): return String(describing: underlying)
        case .invalidProfile(let reason): return "Profile is structurally invalid: \(reason)"
        }
    }
}
