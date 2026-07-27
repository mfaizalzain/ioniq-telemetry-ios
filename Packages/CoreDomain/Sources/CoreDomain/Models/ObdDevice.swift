import Foundation

public struct ObdDevice: Sendable, Identifiable, Equatable {
    public var id: String { address }
    public var name: String
    public var address: String
    public var type: ObdDeviceType
    public var isPaired: Bool

    public init(name: String, address: String, type: ObdDeviceType = .ble, isPaired: Bool = false) {
        self.name = name
        self.address = address
        self.type = type
        self.isPaired = isPaired
    }
}

public enum ObdDeviceType: String, Sendable, CaseIterable {
    case ble
    case spp
    case wifi
}
