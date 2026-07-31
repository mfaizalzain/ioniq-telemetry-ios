import Combine
import Foundation

/// App-wide flag for whether a CarPlay session is currently connected.
///
/// The CarPlay scene only exists while a car is actually attached, so phone-side
/// UI (and anything else) reads `isConnected` instead of trying to reach into
/// the scene's objects. The `CarPlaySceneDelegate` flips it on `didConnect` /
/// `didDisconnect`.
final class CarPlayConnectionMonitor: @unchecked Sendable {
    static let shared = CarPlayConnectionMonitor()

    let isConnected = CurrentValueSubject<Bool, Never>(false)

    private init() {}

    func setConnected(_ connected: Bool) {
        isConnected.value = connected
    }
}
