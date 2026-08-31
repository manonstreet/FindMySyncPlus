import XCTest
import CryptoKit
@testable import FindMySyncPlus

final class CacheDecryptorTests: XCTestCase {

    // MARK: - parseDeviceArray

    func testParseDeviceArray_validDevice() {
        let decryptor = CacheDecryptor()
        let input: [[String: Any]] = [[
            "baUUID": "test-uuid-123",
            "name": "Test AirTag",
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
        XCTAssertEqual(result[0].name, "Test AirTag")
        XCTAssertEqual(result[0].latitude, 37.7749, accuracy: 0.0001)
        XCTAssertEqual(result[0].longitude, -122.4194, accuracy: 0.0001)
        XCTAssertEqual(result[0].accuracy, 5.0, accuracy: 0.001)
        XCTAssertEqual(result[0].battery ?? 0, 0.8, accuracy: 0.001)
    }

    func testParseDeviceArray_skipsNoLocation() {
        let decryptor = CacheDecryptor()
        let input: [[String: Any]] = [[
            "baUUID": "no-loc-uuid",
            "name": "No Location Device"
        ]]
        let result = decryptor.parseDeviceArray(input)
        XCTAssertEqual(result.count, 0)
    }

    // MARK: - crowdSourcedLocation fallback

    /// Find My shows a device at a place with an age — "Home · 9 hr. ago" — while
    /// FindMySyncPlus published nothing at all, because only `location` was read.
    ///
    /// The fallback is guarded on `isOld == false`, which separates the two cases
    /// cleanly: every crowdsourced record sitting behind a working primary location
    /// reads old (19–244 h, sometimes hundreds of km away), while the one record with
    /// no primary reads fresh. Publishing an old sighting would move the Home
    /// Assistant entity into the wrong zone, since HA derives zone state from the
    /// coordinates and ignores `is_old`.
    private func record(location: Any?, crowdSourced: Any?) -> [String: Any] {
        var d: [String: Any] = ["baUUID": "fallback-uuid", "name": "Test Device"]
        if let location { d["location"] = location }
        if let crowdSourced { d["crowdSourcedLocation"] = crowdSourced }
        return d
    }

    /// The eleven keys Apple actually writes, measured off a live `Devices.data` and
    /// matching the shape posted on #19. `timeStamp` is an **Int** of milliseconds,
    /// not a Double — it bridges through NSNumber either way, which is precisely why
    /// a fixture using the wrong type would never reveal a problem.
    private func crowdDict(isOld: Bool?, positionType: String = "crowdsourced") -> [String: Any] {
        var d: [String: Any] = [
            "latitude": 51.5, "longitude": -0.12,
            "horizontalAccuracy": 75.6, "verticalAccuracy": 37.8,
            "altitude": 32.0, "floorLevel": 0.0,
            "isInaccurate": false, "locationFinished": true,
            "positionType": positionType,
            // `NSNumber`, not a native `Int`, because that is what
            // `PropertyListSerialization` hands back and the parse reads it as
            // `as? Double`. A native Int does *not* satisfy that cast, so writing one
            // here fails the test while real data works — unfaithful in the opposite
            // direction from the Double this used to be.
            "timeStamp": NSNumber(value: 1_700_000_000_000 as Int64)
        ]
        if let isOld { d["isOld"] = isOld }
        return d
    }

    func testFallback_usedWhenLocationIsNullAndSightingIsFresh() throws {
        let points = CacheDecryptor().parseDeviceArray(
            [record(location: "$null", crowdSourced: crowdDict(isOld: false))])

        let p = try XCTUnwrap(points.first)
        XCTAssertEqual(p.latitude, 51.5)
        XCTAssertEqual(p.longitude, -0.12)
        XCTAssertEqual(p.accuracy, 75.6)
        // Freshness must come from the dict actually used, not from the absent one.
        XCTAssertEqual(p.richAttributes?.isOld, false)
        XCTAssertNotNil(p.richAttributes?.timestamp)
        XCTAssertEqual(p.richAttributes?.positionType, "crowdsourced")
    }

    /// The case that would put a phone at Home while its owner stands at the office.
    func testFallback_notUsedWhenSightingIsOld() {
        let points = CacheDecryptor().parseDeviceArray(
            [record(location: "$null", crowdSourced: crowdDict(isOld: true))])

        XCTAssertTrue(points.isEmpty, "an old sighting must not be published")
    }

    /// Absent is not false. Apple saying nothing about staleness is a different
    /// statement from Apple calling the fix current, and only the latter rescues.
    func testFallback_notUsedWhenStalenessIsUnstated() {
        let points = CacheDecryptor().parseDeviceArray(
            [record(location: "$null", crowdSourced: crowdDict(isOld: nil))])

        XCTAssertTrue(points.isEmpty)
    }

    func testFallback_notUsedWhenNeitherIsUsable() {
        let points = CacheDecryptor().parseDeviceArray(
            [record(location: "$null", crowdSourced: nil)])

        XCTAssertTrue(points.isEmpty)
    }

    /// `location` is the fresher of the two whenever it exists, so it always wins —
    /// including over a sighting that claims to be fresh.
    func testFallback_realLocationAlwaysWins() throws {
        let live: [String: Any] = [
            "latitude": 10.0, "longitude": 20.0, "horizontalAccuracy": 5.0,
            "positionType": "Wifi", "isOld": false
        ]
        let points = CacheDecryptor().parseDeviceArray(
            [record(location: live, crowdSourced: crowdDict(isOld: false))])

        let p = try XCTUnwrap(points.first)
        XCTAssertEqual(p.latitude, 10.0)
        XCTAssertEqual(p.accuracy, 5.0)
        XCTAssertEqual(p.richAttributes?.positionType, "Wifi")
    }

    /// An unmapped Apple value must stay visible rather than be folded into a
    /// plausible default — `GPS` and `ownedDeviceLocation` both appear in the wild.
    func testPositionType_passesThroughUnmappedValues() throws {
        let points = CacheDecryptor().parseDeviceArray(
            [record(location: "$null", crowdSourced: crowdDict(isOld: false, positionType: "GPS"))])

        let p = try XCTUnwrap(points.first)
        XCTAssertEqual(p.richAttributes?.positionType, "GPS")
    }

    /// Every FMIP record carries `altitude` and `verticalAccuracy` — measured on both
    /// `Devices.data` and `Items.data` — and `MQTTClient` already knows how to publish
    /// them. They were passed as `nil` here, so devices and items dropped two values
    /// Apple hands us while friends published them.
    ///
    func testParseDeviceArray_carriesAltitudeAndVerticalAccuracy() throws {
        let points = CacheDecryptor().parseDeviceArray([[
            "baUUID": "alt-uuid",
            "name": "Test Device",
            "location": ["latitude": 1.0, "longitude": 2.0, "horizontalAccuracy": 5.0,
                         "verticalAccuracy": 3.5, "altitude": 32.0]
        ]])

        let p = try XCTUnwrap(points.first)
        XCTAssertEqual(p.richAttributes?.altitude, 32.0)
        XCTAssertEqual(p.richAttributes?.verticalAccuracy, 3.5)
        XCTAssertNil(p.richAttributes?.speed, "absent from this record, so absent here")
        XCTAssertNil(p.richAttributes?.course, "absent from this record, so absent here")
    }

    /// `speed` and `course` were on none of the 25 devices and 5 items measured — but
    /// that was a single instant with nothing moving, and a field that appears only in
    /// motion is indistinguishable from one that never appears. So they are read
    /// rather than hard-coded to nil: if Apple does populate them, they travel.
    func testParseDeviceArray_carriesSpeedAndCourseWhenPresent() throws {
        let points = CacheDecryptor().parseDeviceArray([[
            "baUUID": "motion-uuid",
            "name": "Test Device",
            "location": ["latitude": 1.0, "longitude": 2.0, "horizontalAccuracy": 5.0,
                         "speed": 4.2, "course": 271.5]
        ]])

        let p = try XCTUnwrap(points.first)
        XCTAssertEqual(p.richAttributes?.speed, 4.2)
        XCTAssertEqual(p.richAttributes?.course, 271.5)
    }

    func testParseDeviceArray_emptyInput() {
        let decryptor = CacheDecryptor()
        let result = decryptor.parseDeviceArray([])
        XCTAssertEqual(result.count, 0)
    }

    func testParseDeviceArray_batteryStringFull() {
        let decryptor = CacheDecryptor()
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
        let decryptor = CacheDecryptor()
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

    // MARK: - parseDeviceArray groupParentIDs plumbing

    func testParseDeviceArray_childGetsParentID() {
        let decryptor = CacheDecryptor()
        let parentID = "PARENT-UUID-1"
        let groupParentIDs = ["GROUP-1": parentID]
        let input: [[String: Any]] = [[
            "identifier": "CHILD-A",
            "groupIdentifier": "GROUP-1",
            "name": "Case",
            "location": ["latitude": 1.0, "longitude": 1.0, "horizontalAccuracy": 1.0]
        ]]
        let result = decryptor.parseDeviceArray(input, groupParentIDs: groupParentIDs)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].parentID, parentID)
        XCTAssertEqual(result[0].name, "Case")
    }

    func testParseDeviceArray_unknownGroupIdentifierLeavesParentIDNil() {
        let decryptor = CacheDecryptor()
        let input: [[String: Any]] = [[
            "identifier": "ITEM",
            "groupIdentifier": "UNKNOWN-GROUP",
            "name": "Left Bud",
            "location": ["latitude": 1.0, "longitude": 1.0, "horizontalAccuracy": 1.0]
        ]]
        let result = decryptor.parseDeviceArray(input, groupParentIDs: ["OTHER": "X"])
        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result[0].parentID)
    }

    func testParseDeviceArray_noGroupArgKeepsParentIDNil() {
        let decryptor = CacheDecryptor()
        let input: [[String: Any]] = [[
            "identifier": "PLAIN",
            "name": "AirTag",
            "location": ["latitude": 1.0, "longitude": 1.0, "horizontalAccuracy": 1.0]
        ]]
        let result = decryptor.parseDeviceArray(input)
        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result[0].parentID)
    }

    // MARK: - extractSymmetricKey

    func testExtractSymmetricKey_validBase64String() throws {
        let rawKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let base64 = rawKey.base64EncodedString()
        let result = try CacheDecryptor.extractSymmetricKey(from: base64)
        XCTAssertEqual(result, rawKey)
    }

    func testExtractSymmetricKey_rawData32Bytes() throws {
        let rawKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let result = try CacheDecryptor.extractSymmetricKey(from: rawKey)
        XCTAssertEqual(result, rawKey)
    }

    func testExtractSymmetricKey_nestedDict() throws {
        let rawKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let base64 = rawKey.base64EncodedString()
        let dict: [String: Any] = ["symmetricKey": base64]
        let result = try CacheDecryptor.extractSymmetricKey(from: dict)
        XCTAssertEqual(result, rawKey)
    }

    func testExtractSymmetricKey_wrongLength() throws {
        let shortKey = Data([0x01, 0x02, 0x03])
        let result = try CacheDecryptor.extractSymmetricKey(from: shortKey)
        XCTAssertNil(result)
    }

    // MARK: - readEncryptedPayload (activated after actor conversion in Task 6)

    func testReadEncryptedPayload_missingFile() async {
        let decryptor = CacheDecryptor()
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

        let decryptor = CacheDecryptor()
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

        let decryptor = CacheDecryptor()
        let logStore = LogStore()
        await decryptor.loadKeyForTesting(wrongKey)
        let result = await decryptor.decryptPayload(payload, logger: logStore)

        if case .failure(.incorrectKey) = result { } else {
            XCTFail("Expected .incorrectKey, got \(result)")
        }
    }

    func testDecryptPayload_noKeyLoaded() async {
        let decryptor = CacheDecryptor()
        let logStore = LogStore()
        let result = await decryptor.decryptPayload(Data(), logger: logStore)
        if case .failure(.keyNotLoaded) = result { } else {
            XCTFail("Expected .keyNotLoaded, got \(result)")
        }
    }
}
