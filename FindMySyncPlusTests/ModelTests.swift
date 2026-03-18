import XCTest
@testable import FindMySyncPlus

final class DevicePointTests: XCTestCase {

    private let base = DevicePoint(id: "abc123", name: "Test Device",
                                   latitude: 37.33, longitude: -122.03,
                                   accuracy: 10.0, battery: 0.85,
                                   prsId: "owner",
                                   richAttributes: RichLocationAttributes(
                                       verticalAccuracy: 5.0, altitude: 100.0,
                                       speed: 1.5, course: 90.0,
                                       timestamp: nil, motionActivityState: 2,
                                       locationLabel: "Home"))

    func testWith_nameOverride() {
        let updated = base.with(name: "New Name")
        XCTAssertEqual(updated.name, "New Name")
        XCTAssertEqual(updated.id, base.id)
        XCTAssertEqual(updated.latitude, base.latitude)
        XCTAssertEqual(updated.longitude, base.longitude)
        XCTAssertEqual(updated.accuracy, base.accuracy)
        XCTAssertEqual(updated.battery, base.battery)
        XCTAssertEqual(updated.prsId, base.prsId)
        XCTAssertEqual(updated.richAttributes?.altitude, base.richAttributes?.altitude)
    }

    func testWith_richAttributesOverride() {
        let newRich = RichLocationAttributes(
            verticalAccuracy: nil, altitude: 200.0,
            speed: nil, course: nil,
            timestamp: nil, motionActivityState: nil,
            locationLabel: nil)
        let updated = base.with(richAttributes: newRich)
        XCTAssertEqual(updated.richAttributes?.altitude, 200.0)
        XCTAssertNil(updated.richAttributes?.speed)
        XCTAssertEqual(updated.name, base.name)
    }

    func testWith_noOverrides() {
        let updated = base.with()
        XCTAssertEqual(updated.id, base.id)
        XCTAssertEqual(updated.name, base.name)
        XCTAssertEqual(updated.latitude, base.latitude)
        XCTAssertEqual(updated.battery, base.battery)
        XCTAssertEqual(updated.prsId, base.prsId)
        XCTAssertEqual(updated.richAttributes?.locationLabel, "Home")
    }

    func testWith_nilBatteryPreserved() {
        let noBattery = DevicePoint(id: "x", name: "X",
                                    latitude: 0, longitude: 0,
                                    accuracy: 0, battery: nil)
        let updated = noBattery.with(name: "Y")
        XCTAssertNil(updated.battery)
        XCTAssertEqual(updated.name, "Y")
    }
}

final class RichLocationAttributesTests: XCTestCase {

    func testMotionStateDescription() {
        let cases: [(Int?, String)] = [
            (0, "Unknown"),
            (1, "Stationary"),
            (2, "Walking"),
            (3, "Running"),
            (4, "Automotive"),
            (5, "Cycling"),
            (6, "Unknown"),
            (99, "Unknown"),
            (nil, "Unknown"),
        ]
        for (state, expected) in cases {
            let rich = RichLocationAttributes(
                verticalAccuracy: nil, altitude: nil,
                speed: nil, course: nil,
                timestamp: nil, motionActivityState: state,
                locationLabel: nil)
            XCTAssertEqual(rich.motionStateDescription, expected,
                           "motionActivityState \(String(describing: state)) should be \(expected)")
        }
    }
}
