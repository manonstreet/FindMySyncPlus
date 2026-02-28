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

    // MARK: - extractSymmetricKey

    func testExtractSymmetricKey_validBase64String() throws {
        let rawKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let base64 = rawKey.base64EncodedString()
        let result = try Decryptor.extractSymmetricKey(from: base64)
        XCTAssertEqual(result, rawKey)
    }

    func testExtractSymmetricKey_rawData32Bytes() throws {
        let rawKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let result = try Decryptor.extractSymmetricKey(from: rawKey)
        XCTAssertEqual(result, rawKey)
    }

    func testExtractSymmetricKey_nestedDict() throws {
        let rawKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let base64 = rawKey.base64EncodedString()
        let dict: [String: Any] = ["symmetricKey": base64]
        let result = try Decryptor.extractSymmetricKey(from: dict)
        XCTAssertEqual(result, rawKey)
    }

    func testExtractSymmetricKey_wrongLength() throws {
        let shortKey = Data([0x01, 0x02, 0x03])
        let result = try Decryptor.extractSymmetricKey(from: shortKey)
        XCTAssertNil(result)
    }
}
