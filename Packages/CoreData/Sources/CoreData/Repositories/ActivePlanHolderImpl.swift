import Combine
import CoreDomain
import Foundation

/// In-memory holder for the active trip plan, shared between the phone UI, the
/// drive service and CarPlay.
///
/// Deliberately not persisted: a plan is only meaningful for the drive it was made
/// for, and restoring yesterday's plan on launch would have the replan monitor
/// comparing today's drive against it.
public final class ActivePlanHolderImpl: ActivePlanHolder, @unchecked Sendable {

    private let _activePlan = CurrentValueSubject<TripPlan?, Never>(nil)
    private let _routePoints = CurrentValueSubject<[LatLon], Never>([])
    private let _replanAdvice = CurrentValueSubject<String?, Never>(nil)
    private let _pendingReroute = CurrentValueSubject<TripPlan?, Never>(nil)
    private var pendingReroutePoints: [LatLon] = []
    private let lock = NSLock()

    public var activePlan: AnyPublisher<TripPlan?, Never> { _activePlan.eraseToAnyPublisher() }
    public var routePoints: AnyPublisher<[LatLon], Never> { _routePoints.eraseToAnyPublisher() }
    public var replanAdvice: AnyPublisher<String?, Never> { _replanAdvice.eraseToAnyPublisher() }
    public var pendingReroute: AnyPublisher<TripPlan?, Never> { _pendingReroute.eraseToAnyPublisher() }

    /// Current values for callers that need a snapshot rather than a subscription.
    public var currentPlan: TripPlan? { _activePlan.value }
    public var currentRoutePoints: [LatLon] { _routePoints.value }

    public init() {}

    public func setPlan(_ plan: TripPlan?) {
        _activePlan.value = plan
        // Advice describes the old plan; carrying it over would be a lie about the
        // new one.
        _replanAdvice.value = nil
        _pendingReroute.value = nil
    }

    public func setRoute(_ points: [LatLon]) {
        _routePoints.value = points
    }

    public func clearPlan() {
        _activePlan.value = nil
        _routePoints.value = []
        _replanAdvice.value = nil
        _pendingReroute.value = nil
        lock.withLock { pendingReroutePoints = [] }
    }

    public func setReplanAdvice(_ message: String?) {
        _replanAdvice.value = message
    }

    public func setPendingReroute(_ plan: TripPlan, points: [LatLon]) {
        lock.withLock { pendingReroutePoints = points }
        _pendingReroute.value = plan
    }

    public func commitPendingReroute() -> TripPlan? {
        guard let plan = _pendingReroute.value else { return nil }
        let points = lock.withLock { pendingReroutePoints }
        _activePlan.value = plan
        _routePoints.value = points
        _replanAdvice.value = nil
        _pendingReroute.value = nil
        lock.withLock { pendingReroutePoints = [] }
        return plan
    }
}
