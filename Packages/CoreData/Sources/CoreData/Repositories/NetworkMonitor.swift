import Combine
import Foundation
import Network

/// Whether the device currently has usable internet.
///
/// Ported from Android `NetworkMonitor.kt`. Used to say "you are offline" up front
/// instead of making the driver wait for a request to time out first, and to tell a
/// genuine provider outage apart from no signal — on a road trip those need
/// different words and different advice.
///
/// Android checks `NET_CAPABILITY_VALIDATED` so a connected-but-useless network (a
/// hotel captive portal, a cell with bars and no backhaul) isn't treated as online.
/// `NWPath` has no exact equivalent, but `.satisfied` combined with
/// `isConstrained`/`isExpensive` reporting is the closest available signal, and a
/// captive portal still surfaces as a failed request that `userMessage` explains.
public final class NetworkMonitor: @unchecked Sendable {

    public static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.fmz.ioniqtelemetry.network-monitor")
    private let subject = CurrentValueSubject<Bool, Never>(true)

    /// Emits on every connectivity change, for UI that shows an offline banner.
    public var online: AnyPublisher<Bool, Never> {
        subject.removeDuplicates().eraseToAnyPublisher()
    }

    /// Point-in-time check, for a decision made before starting a request.
    public var isOnline: Bool { subject.value }

    private init() {
        // Starts optimistic: NWPathMonitor reports its first path asynchronously,
        // and briefly claiming "offline" at launch would flash a banner on a device
        // that is perfectly online.
        monitor.pathUpdateHandler = { [weak self] path in
            self?.subject.send(path.status == .satisfied)
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}
