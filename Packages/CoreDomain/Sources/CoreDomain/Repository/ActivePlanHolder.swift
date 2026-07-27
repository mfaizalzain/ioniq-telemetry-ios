import Combine

/// The most recently generated trip plan, shared between phone UI and Android Auto.
public protocol ActivePlanHolder: Sendable {
    /// Publisher emitting the active trip plan.
    var activePlan: AnyPublisher<TripPlan?, Never> { get }

    /// The routed polyline for the active plan, used to match the live GPS position
    /// onto the route (distance-along and off-route). Empty until a plan is routed.
    var routePoints: AnyPublisher<[LatLon], Never> { get }

    /// Advice from the live re-plan monitor when real consumption drifts from the
    /// plan; null when the plan is on track. Cleared whenever a new plan is set.
    var replanAdvice: AnyPublisher<String?, Never> { get }

    /// A re-route to a reachable alternative charger, computed when an occupancy
    /// alert fires but held until the driver taps "Re-route". Not yet the active
    /// plan — [commitPendingReroute] promotes it.
    var pendingReroute: AnyPublisher<TripPlan?, Never> { get }

    /// Set the active trip plan. Clears any prior replan advice.
    func setPlan(_ plan: TripPlan?)

    /// Set the route polyline points for the active plan.
    func setRoute(_ points: [LatLon])

    /// Drops the active plan and everything derived from it.
    func clearPlan()

    /// Set replan advice message.
    func setReplanAdvice(_ message: String?)

    /// Set a pending re-route plan with its route points.
    func setPendingReroute(_ plan: TripPlan, points: [LatLon])

    /// Promotes the pending re-route to the active plan ("add to plan first"),
    /// returning it so the caller can hand it to Google Maps. Null if none pending.
    func commitPendingReroute() -> TripPlan?
}
