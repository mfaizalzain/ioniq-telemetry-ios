import Foundation

/// The driver's fitted consumption calibration, as persisted across launches.
///
/// Lives in CoreDomain (not CoreRouting) because `UserPreferences` cannot depend
/// on CoreRouting — CoreRouting depends on CoreDomain. CoreRouting maps this to
/// its `CalibrationFactors` when building models.
public struct CalibrationSnapshot: Sendable, Equatable {
    public var crrScale: Float
    public var cdaScale: Float
    public var auxScale: Float
    /// Driving distance the fit is based on. Below `CalibrationFactors`
    /// thresholds the calibration is not applied yet.
    public var fittedSampleKm: Float

    public static let unset = CalibrationSnapshot(
        crrScale: 0,
        cdaScale: 0,
        auxScale: 0,
        fittedSampleKm: 0
    )

    public init(crrScale: Float, cdaScale: Float, auxScale: Float, fittedSampleKm: Float) {
        self.crrScale = crrScale
        self.cdaScale = cdaScale
        self.auxScale = auxScale
        self.fittedSampleKm = fittedSampleKm
    }

    /// True once a calibration has been persisted at all. The *applicability*
    /// of a stored calibration (enough fitted distance) is CoreRouting's call.
    public var isSet: Bool { fittedSampleKm > 0 }
}
