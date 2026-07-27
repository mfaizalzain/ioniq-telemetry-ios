import Combine

/// The single source of truth for whether the car is parked, shared between the
/// phone UI and Android Auto.
///
/// Written by `ConnectedCarService` (the only component that owns the motion
/// signal); read by anything that wants to restrict a surface while driving.
/// Consumers should branch on [ParkedState.allowsAttentionHeavyUi] rather than
/// comparing the enum themselves.
///
/// Lives in `:core-domain` for the same reason `ActivePlanHolder` does — `:auto`
/// cannot see `:app`, and both surfaces need the same answer.
public protocol VehicleMotionHolder: Sendable {
    /// Publisher emitting the current parked/motion state.
    var parkedState: AnyPublisher<ParkedState, Never> { get }

    /// Whether the vehicle is currently in motion (derived from parkedState).
    var inVehicle: AnyPublisher<Bool, Never> { get }

    /// Update the parked state.
    func set(_ state: ParkedState)

    /// Back to [ParkedState.unknown].
    ///
    /// Called when the writer stops observing (adapter disconnected, service torn
    /// down). Without it a service killed mid-drive would leave [moving] latched
    /// forever, and every gated surface would stay locked with nothing left
    /// running to unlock it.
    func reset()
}
