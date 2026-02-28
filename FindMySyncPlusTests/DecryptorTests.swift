import XCTest
import CryptoKit
@testable import FindMySyncPlus

final class DecryptorTests: XCTestCase {

    // MARK: - parseDeviceArray

    func testParseDeviceArray_validDevice() {
        let decryptor = Decryptor()
        let input: [[String: Any]] = [[
            "baUUID": "test-uuid-123",
            "name": "Joel's AirTag",
            "location": [
                "latitude": 37.7749,
                "longitude": -122.4194,
                "horizontalAccuracy": 5.0
            ],
            "batteryLevel": 0.8
        ]]
        let result = decryptor.parseDeviceArray(input)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, "test-uuid-123")
        XCTAssertEqual(result[0].name, "Joel's AirTag")
        XCTAssertEqual(result[0].latitude, 37.7749, accuracy: 0.0001)
        XCTAssertEqual(result[0].longitude, -122.4194, accuracy: 0.0001)
        XCTAssertEqual(result[0].accuracy, 5.0, accuracy: 0.001)
        XCTAssertEqual(result[0].battery ?? 0, 0.8, accuracy: 0.001)
    }

    func testParseDeviceArray_skipsNoLocation() {
        let decryptor = Decryptor()
        let input: [[String: Any]] = [[
            "baUUID": "no-loc-uuid",
            "name": "No Location Device"
        ]]
        let result = decryptor.parseDeviceArray(input)
        XCTAssertEqual(result.count, 0)
    }

    func testParseDeviceArray_emptyInput() {
        let decryptor = Decryptor()
        let result = decryptor.parseDeviceArray([])
        XCTAssertEqual(result.count, 0)
    }

    func testParseDeviceArray_batteryStringFull() {
        let decryptor = Decryptor()
        let input: [[String: Any]] = [[
            "baUUID": "uuid-1",
            "name": "Test",
            "location": ["latitude": 1.0, "longitude": 1.0, "horizontalAccuracy": 1.0],
            "batteryStatus": "full"
        ]]
        let result = decryptor.parseDeviceArray(input)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].battery ?? 0, 1.0, accuracy: 0.001)
    }

    func testParseDeviceArray_batteryStringLow() {
        let decryptor = Decryptor()
        let input: [[String: Any]] = [[
            "baUUID": "uuid-2",
            "name": "Test",
            "location": ["latitude": 1.0, "longitude": 1.0, "horizontalAccuracy": 1.0],
            "batteryStatus": "low"
        ]]
        let result = decryptor.parseDeviceArray(input)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].battery ?? 0, 0.25, accuracy: 0.001)
    }
}
