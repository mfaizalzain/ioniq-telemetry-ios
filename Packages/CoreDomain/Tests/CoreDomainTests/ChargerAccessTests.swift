import Testing
@testable import CoreDomain

/// Usage-type IDs are not ordered by openness, so the previous rule (`ID == 2 ||
/// ID == 3`) let type 6 — "Private — For Staff, Visitors or Customers" — through.
struct ChargerAccessTests {

    @Test("private usage types are restricted", arguments: [2, 3, 6])
    func privateTypesRestricted(id: Int) {
        #expect(ChargerAccess.isRestricted(usageTypeId: id, isAccessKeyRequired: nil, name: "Some Site"))
    }

    @Test("open public types are not restricted", arguments: [1, 5, 7])
    func publicTypesAllowed(id: Int) {
        #expect(!ChargerAccess.isRestricted(usageTypeId: id, isAccessKeyRequired: false, name: "Some Site"))
    }

    /// OCM sets IsAccessKeyRequired on membership sites, so they are filtered by
    /// that flag rather than by usage type. Matches the Android build.
    @Test("membership-required sites are filtered via the access-key flag")
    func membershipFilteredByAccessKey() {
        #expect(ChargerAccess.isRestricted(usageTypeId: 4, isAccessKeyRequired: true, name: "DC Fast"))
    }

    @Test("an access key makes any site unusable to a passing driver")
    func accessKeyRestricts() {
        #expect(ChargerAccess.isRestricted(usageTypeId: 1, isAccessKeyRequired: true, name: "Public Site"))
    }

    @Test("restricted-looking names are caught when the usage type is missing")
    func nameFallback() {
        #expect(ChargerAccess.isRestricted(usageTypeId: nil, isAccessKeyRequired: nil, name: "[Restricted] Condo"))
        #expect(ChargerAccess.isRestricted(usageTypeId: nil, isAccessKeyRequired: nil, name: "Private Residence"))
        #expect(!ChargerAccess.isRestricted(usageTypeId: nil, isAccessKeyRequired: nil, name: "Shell Recharge"))
    }

    @Test("an unknown record with no signals is allowed rather than silently dropped")
    func unknownIsAllowed() {
        #expect(!ChargerAccess.isRestricted(usageTypeId: nil, isAccessKeyRequired: nil, name: nil))
    }
}
