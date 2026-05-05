import XCTest
@testable import FindMySyncPlus

@MainActor
final class SyncEngineGroupingTests: XCTestCase {

    private static let parentID = "11111111-1111-1111-1111-111111111111"
    private static let childAID = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    private static let childBID = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
    private static let aliasKey = "left-bud-alias"

    private func makePoint(id: String, parentID: String? = nil) -> DevicePoint {
        DevicePoint(id: id, name: id, latitude: 1, longitude: 1, accuracy: 1,
                    battery: nil, parentID: parentID)
    }

    // MARK: - filterHiddenGroupedChildren

    func testFilter_disabled_returnsEverything() {
        let engine = SyncEngine()
        let points = [
            makePoint(id: Self.parentID),
            makePoint(id: Self.childAID, parentID: Self.parentID),
            makePoint(id: Self.childBID, parentID: Self.parentID)
        ]
        let result = engine.filterHiddenGroupedChildren(points, aliasByUUID: [:], hideEnabled: false)
        XCTAssertEqual(result.count, 3)
    }

    func testFilter_enabled_keepsParents_dropsUnaliasedChildren() {
        let engine = SyncEngine()
        let points = [
            makePoint(id: Self.parentID),
            makePoint(id: Self.childAID, parentID: Self.parentID),
            makePoint(id: Self.childBID, parentID: Self.parentID)
        ]
        let result = engine.filterHiddenGroupedChildren(points, aliasByUUID: [:], hideEnabled: true)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, Self.parentID)
    }

    func testFilter_enabled_keepsAliasedChildren() {
        let engine = SyncEngine()
        let points = [
            makePoint(id: Self.parentID),
            makePoint(id: Self.childAID, parentID: Self.parentID),
            makePoint(id: Self.childBID, parentID: Self.parentID)
        ]
        // Alias map is keyed by normalized id (hex-only, lowercased).
        let alias = [Self.childAID.normalized(): Self.aliasKey]
        let result = engine.filterHiddenGroupedChildren(points, aliasByUUID: alias, hideEnabled: true)
        let ids = Set(result.map { $0.id })
        XCTAssertEqual(ids, [Self.parentID, Self.childAID])
    }

    func testFilter_enabled_ignoresUngroupedItems() {
        let engine = SyncEngine()
        let points = [
            makePoint(id: "AABB1111-2222-3333-4444-555566667777"),
            makePoint(id: "CCDD8888-9999-AAAA-BBBB-CCCCCCCCCCCC")
        ]
        let result = engine.filterHiddenGroupedChildren(points, aliasByUUID: [:], hideEnabled: true)
        XCTAssertEqual(result.count, 2)
    }

    // MARK: - backfillParentLocations

    private func parentRaw(id: String, lat: Double, ts: Double, isOld: Bool) -> [String: Any] {
        return [
            "baUUID": id,
            "name": id,
            "itemGroup": ["items": [Any]()],
            "location": [
                "latitude": lat,
                "longitude": lat,
                "horizontalAccuracy": 1.0,
                "timeStamp": ts,
                "isOld": isOld
            ]
        ]
    }

    private func childRaw(id: String, parentID: String, lat: Double, ts: Double) -> [String: Any] {
        return [
            "identifier": id,
            "groupIdentifier": parentID,
            "name": id,
            "location": [
                "latitude": lat,
                "longitude": lat,
                "horizontalAccuracy": 1.0,
                "timeStamp": ts,
                "isOld": false
            ]
        ]
    }

    private func parsedDevicePoint(from raw: [String: Any], parentID: String? = nil) -> DevicePoint {
        let loc = raw["location"] as? [String: Any]
        let id = (raw["baUUID"] as? String) ?? (raw["identifier"] as? String) ?? "?"
        return DevicePoint(
            id: id,
            name: (raw["name"] as? String) ?? id,
            latitude: (loc?["latitude"] as? Double) ?? 0,
            longitude: (loc?["longitude"] as? Double) ?? 0,
            accuracy: (loc?["horizontalAccuracy"] as? Double) ?? 0,
            battery: nil,
            parentID: parentID
        )
    }

    func testBackfill_isOldParent_replacedByFreshestChild() {
        let engine = SyncEngine()
        let pid = "AAAAAAAA-1111-1111-1111-111111111111"
        let aRaw = childRaw(id: "AAAAAAAA-2222-2222-2222-222222222222",
                            parentID: pid, lat: 20.0, ts: 5000)
        let bRaw = childRaw(id: "AAAAAAAA-3333-3333-3333-333333333333",
                            parentID: pid, lat: 30.0, ts: 7000)
        let pRaw = parentRaw(id: pid, lat: 10.0, ts: 1000, isOld: true)

        let parent = parsedDevicePoint(from: pRaw)
        let childA = parsedDevicePoint(from: aRaw, parentID: pid)
        let childB = parsedDevicePoint(from: bRaw, parentID: pid)

        let result = engine.backfillParentLocations(
            parents: [parent], children: [childA, childB],
            rawDevices: [pRaw], rawItems: [aRaw, bRaw]
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, pid)
        XCTAssertEqual(result[0].latitude, 30.0, accuracy: 0.001)
    }

    func testBackfill_freshParent_unchanged() {
        let engine = SyncEngine()
        let pid = "BBBBBBBB-1111-1111-1111-111111111111"
        let pRaw = parentRaw(id: pid, lat: 10.0, ts: 8000, isOld: false)
        let aRaw = childRaw(id: "BBBBBBBB-2222-2222-2222-222222222222",
                            parentID: pid, lat: 20.0, ts: 5000)

        let parent = parsedDevicePoint(from: pRaw)
        let childA = parsedDevicePoint(from: aRaw, parentID: pid)

        let result = engine.backfillParentLocations(
            parents: [parent], children: [childA],
            rawDevices: [pRaw], rawItems: [aRaw]
        )
        XCTAssertEqual(result[0].latitude, 10.0, accuracy: 0.001)
    }

    func testBackfill_parentMuchOlderThanChild_replaced() {
        let engine = SyncEngine()
        let pid = "CCCCCCCC-1111-1111-1111-111111111111"
        let pRaw = parentRaw(id: pid, lat: 10.0, ts: 1000, isOld: false)
        let aRaw = childRaw(id: "CCCCCCCC-2222-2222-2222-222222222222",
                            parentID: pid, lat: 20.0, ts: 1000 + 120_000) // +2 min

        let parent = parsedDevicePoint(from: pRaw)
        let childA = parsedDevicePoint(from: aRaw, parentID: pid)

        let result = engine.backfillParentLocations(
            parents: [parent], children: [childA],
            rawDevices: [pRaw], rawItems: [aRaw]
        )
        XCTAssertEqual(result[0].latitude, 20.0, accuracy: 0.001)
    }

    func testBackfill_noChildren_keepsParent() {
        let engine = SyncEngine()
        let pid = "DDDDDDDD-1111-1111-1111-111111111111"
        let pRaw = parentRaw(id: pid, lat: 10.0, ts: 1000, isOld: true)
        let parent = parsedDevicePoint(from: pRaw)

        let result = engine.backfillParentLocations(
            parents: [parent], children: [],
            rawDevices: [pRaw], rawItems: []
        )
        XCTAssertEqual(result[0].latitude, 10.0, accuracy: 0.001)
    }
}
