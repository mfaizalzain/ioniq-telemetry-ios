import XCTest
@testable import IoniqTelemetry

/// Minimal host-bundle smoke test. The app's real logic is covered by the
/// CoreOBD / CoreDomain / CoreRouting package test suites; this file exists so
/// the app-hosted `IoniqTelemetryTests` bundle has an executable to load and
/// run at all (an empty bundle fails to load on the simulator).
final class IoniqTelemetrySmokeTests: XCTestCase {
    func testAppBundleLoads() {
        XCTAssertNotNil(Bundle.main.bundleIdentifier)
    }

    func testAppServicesTypeExists() {
        // Reference a real app type so the @testable import is exercised.
        _ = AppServices.self
    }
}
