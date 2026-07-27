import Foundation

/// Whether a charger is usable by a driver who just turns up.
///
/// Open Charge Map classifies access with a `UsageType`. The IDs are stable and
/// documented, but they are not ordered by openness — "Private" is 2, 3 and 6 with
/// public types interleaved — so testing a range or a couple of magic numbers
/// silently lets some private sites through. They are enumerated here instead.
public enum ChargerAccess {

    /// OCM usage types that a passing driver cannot use.
    ///
    /// - 2: Private — Restricted Access
    /// - 3: Privately Owned — Notice Required
    /// - 6: Private — For Staff, Visitors or Customers
    ///
    /// Type 4 (Public — Membership Required) is not listed here, but OCM sets
    /// `IsAccessKeyRequired` on those records, so they are excluded by that check
    /// instead — matching the Android build, which uses the same signal.
    public static let privateUsageTypeIds: Set<Int> = [2, 3, 6]

    /// - Parameters:
    ///   - usageTypeId: OCM `UsageType.ID`, if the record has one.
    ///   - isAccessKeyRequired: OCM `UsageType.IsAccessKeyRequired`. A key, fob or
    ///     network membership means a passing driver cannot simply plug in.
    ///   - name: the site title. OCM data for some regions prefixes restricted
    ///     sites with "[Restricted]" even when the usage type is unset, so the name
    ///     is a last-resort check rather than the primary signal.
    public static func isRestricted(
        usageTypeId: Int?,
        isAccessKeyRequired: Bool?,
        name: String?
    ) -> Bool {
        if let usageTypeId, privateUsageTypeIds.contains(usageTypeId) { return true }
        if isAccessKeyRequired == true { return true }
        return hasRestrictedName(name)
    }

    public static func hasRestrictedName(_ name: String?) -> Bool {
        guard let name else { return false }
        return name.localizedCaseInsensitiveContains("restricted")
            || name.localizedCaseInsensitiveContains("private")
    }
}
