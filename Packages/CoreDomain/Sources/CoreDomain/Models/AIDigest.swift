import Foundation

// MARK: - Digest Period

public enum DigestPeriod: String, Sendable, CaseIterable {
    case weekly = "WEEKLY"
    case monthly = "MONTHLY"

    public var label: String {
        switch self {
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        }
    }
}

// MARK: - AI Digest Model

public struct AIDigest: Sendable, Equatable {
    public let text: String
    public let period: DigestPeriod
    public let generatedAt: Date

    public init(text: String, period: DigestPeriod, generatedAt: Date = Date()) {
        self.text = text
        self.period = period
        self.generatedAt = generatedAt
    }
}

// MARK: - AI Feature Enum

public enum AiFeature: String, Sendable, CaseIterable {
    case postTripBriefing = "POST_TRIP_BRIEFING"
    case weeklyDigest = "WEEKLY_DIGEST"
    case chargingIntelligence = "CHARGING_INTELLIGENCE"
    case batteryHealthReport = "BATTERY_HEALTH_REPORT"
    case copilotWithContext = "COPILOT_WITH_CONTEXT"

    public var title: String {
        switch self {
        case .postTripBriefing: return "AI Trip Briefing"
        case .weeklyDigest: return "Weekly AI Digest"
        case .chargingIntelligence: return "Charging Intelligence"
        case .batteryHealthReport: return "Battery Health Report"
        case .copilotWithContext: return "AI Copilot"
        }
    }

    public var icon: String {
        switch self {
        case .postTripBriefing: return "list.clipboard"
        case .weeklyDigest: return "calendar.badge.clock"
        case .chargingIntelligence: return "bolt.batteryblock"
        case .batteryHealthReport: return "heart.text.clipboard"
        case .copilotWithContext: return "brain.head.profile"
        }
    }

    public var detail: String {
        switch self {
        case .postTripBriefing: return "AI-powered summary after every trip"
        case .weeklyDigest: return "Weekly and monthly driving summaries"
        case .chargingIntelligence: return "Charge speed trends and degradation analysis"
        case .batteryHealthReport: return "SOH tracking and battery health assessment"
        case .copilotWithContext: return "Ask questions about your vehicle with full context"
        }
    }
}
