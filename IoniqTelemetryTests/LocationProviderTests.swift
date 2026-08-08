import CoreLocation
import XCTest
@testable import IoniqTelemetry

/// The nearby-charger list and its live-status search are centered on
/// `LocationProvider.currentLocation()`. A stale cached fix would put both
/// hundreds of km away, so the freshness rule must stay strict.
final class LocationProviderTests: XCTestCase {

    private func location(age: TimeInterval, accuracy: CLLocationAccuracy) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 3.1, longitude: 101.6),
            altitude: 0,
            horizontalAccuracy: accuracy,
            verticalAccuracy: accuracy,
            course: 0,
            speed: 0,
            timestamp: Date().addingTimeInterval(-age)
        )
    }

    func testRecentFixIsFreshEnough() {
        XCTAssertTrue(LocationProvider.isFreshEnough(location(age: 30, accuracy: 50)))
    }

    func testTwoHourOldFixIsNotFreshEnough() {
        XCTAssertFalse(LocationProvider.isFreshEnough(location(age: 7200, accuracy: 50)))
    }

    func testInvalidAccuracyIsNotFreshEnough() {
        XCTAssertFalse(LocationProvider.isFreshEnough(location(age: 0, accuracy: -1)))
    }
}
