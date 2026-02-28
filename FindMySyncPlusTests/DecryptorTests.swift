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

    // MARK: - readEncryptedPayload (activated after actor conversion in Task 6)

    func testReadEncryptedPayload_missingFile() async {
        let decryptor = Decryptor()
        let logStore = LogStore()
        let result = await decryptor.readEncryptedPayload(from: .devices, logger: logStore)
        switch result {
        case .success:
            break // Found a real cache on this machine — valid
        case .failure(.fdaRequired):
            break // No Full Disk Access in CI — valid
        case .failure(.fileReadError):
            break // File missing in CI — valid
        case .failure(let e):
            XCTFail("Unexpected error type: \(e)")
        }
    }

    // MARK: - decryptPayload (activated after actor conversion in Task 6)

    func testDecryptPayload_roundTrip() async throws {
        let key = SymmetricKey(size: .bits256)
        let fakeDevices: [[String: Any]] = [[
            "baUUID": "synthetic-uuid",
            "name": "Test Device",
            "location": ["latitude": 51.5, "longitude": -0.1, "horizontalAccuracy": 10.0]
        ]]
        let plaintext = try PropertyListSerialization.data(
            fromPropertyList: fakeDevices, format: .binary, options: 0)
        let sealed = try ChaChaPoly.seal(plaintext, using: key)
        var payload = Data()
        payload.append(contentsOf: sealed.nonce)
        payload.append(sealed.ciphertext)
        payload.append(sealed.tag)

        let decryptor = Decryptor()
        let logStore = LogStore()
        await decryptor.loadKeyForTesting(key)
        let result = await decryptor.decryptPayload(payload, logger: logStore)

        switch result {
        case .success(let decryptedData):
            switch decryptor.parsePlistData(decryptedData) {
            case .success(let arr):
                XCTAssertEqual(arr.count, 1)
                XCTAssertEqual(arr[0]["baUUID"] as? String, "synthetic-uuid")
                XCTAssertEqual(arr[0]["name"] as? String, "Test Device")
            case .failure(let e):
                XCTFail("Plist parse failed: \(e)")
            }
        case .failure(let e):
            XCTFail("Decryption failed: \(e)")
        }
    }

    func testDecryptPayload_wrongKey() async throws {
        let encryptKey = SymmetricKey(size: .bits256)
        let wrongKey = SymmetricKey(size: .bits256)
        let plaintext = Data("hello".utf8)
        let sealed = try ChaChaPoly.seal(plaintext, using: encryptKey)
        var payload = Data()
        payload.append(contentsOf: sealed.nonce)
        payload.append(sealed.ciphertext)
        payload.append(sealed.tag)

        let decryptor = Decryptor()
        let logStore = LogStore()
        await decryptor.loadKeyForTesting(wrongKey)
        let result = await decryptor.decryptPayload(payload, logger: logStore)

        if case .failure(.incorrectKey) = result { } else {
            XCTFail("Expected .incorrectKey, got \(result)")
        }
    }

    func testDecryptPayload_noKeyLoaded() async {
        let decryptor = Decryptor()
        let logStore = LogStore()
        let result = await decryptor.decryptPayload(Data(), logger: logStore)
        if case .failure(.keyNotLoaded) = result { } else {
            XCTFail("Expected .keyNotLoaded, got \(result)")
        }
    }
}
