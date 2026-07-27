import Foundation

public struct CopilotMessage: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var role: MessageRole
    public var text: String
    public var timestamp: Date

    public enum MessageRole: String, Sendable { case user, assistant }

    public init(id: UUID = UUID(), role: MessageRole, text: String, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
    }
}

public struct CopilotContext: Sendable {
    public var messages: [CopilotMessage]
    public var currentTelemetry: VehicleTelemetry?
    public var nearbyChargers: [Charger]
    public var activePlan: TripPlan?

    public init(
        messages: [CopilotMessage] = [],
        currentTelemetry: VehicleTelemetry? = nil,
        nearbyChargers: [Charger] = [],
        activePlan: TripPlan? = nil
    ) {
        self.messages = messages
        self.currentTelemetry = currentTelemetry
        self.nearbyChargers = nearbyChargers
        self.activePlan = activePlan
    }
}
