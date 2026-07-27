import Foundation

/// Replan triggers (spec §5.3): SOC off prediction by >5 points, or >2 km off
/// route — debounced to at most once per 60 s so stop-start traffic near the
/// threshold cannot trigger continuous replanning.
public final class Replanner: @unchecked Sendable {
    private let socDeviationThreshold: Float
    private let offRouteThresholdKm: Float
    private let debounceMs: Int64
    private let clock: @Sendable () -> Int64

    private var lastReplanAt: Int64 = Int64.min / 2  // first trigger is never debounced

    public init(
        socDeviationThreshold: Float = 5,
        offRouteThresholdKm: Float = 2,
        debounceMs: Int64 = 60_000,
        clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.socDeviationThreshold = socDeviationThreshold
        self.offRouteThresholdKm = offRouteThresholdKm
        self.debounceMs = debounceMs
        self.clock = clock
    }

    public func shouldReplan(
        predictedSoc: Float?, actualSoc: Float?, offRouteKm: Float?
    ) -> Bool {
        let socDeviates: Bool = {
            guard let p = predictedSoc, let a = actualSoc else { return false }
            return abs(p - a) > socDeviationThreshold
        }()
        let offRoute: Bool = {
            guard let d = offRouteKm else { return false }
            return d > offRouteThresholdKm
        }()
        if !socDeviates && !offRoute { return false }

        let now = clock()
        if now - lastReplanAt < debounceMs { return false }
        lastReplanAt = now
        return true
    }
}
