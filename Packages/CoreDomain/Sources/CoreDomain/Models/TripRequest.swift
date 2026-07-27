import Foundation

/// Structured trip intent extracted from a natural-language request by the AI parser.
public struct ParsedTripRequest: Sendable, Equatable {
    public var origin: String?
    public var destination: String?
    public var waypoints: [String]
    public var arrivalSocPercent: Float?

    public init(origin: String? = nil, destination: String? = nil, waypoints: [String] = [], arrivalSocPercent: Float? = nil) {
        self.origin = origin
        self.destination = destination
        self.waypoints = waypoints
        self.arrivalSocPercent = arrivalSocPercent
    }
}
