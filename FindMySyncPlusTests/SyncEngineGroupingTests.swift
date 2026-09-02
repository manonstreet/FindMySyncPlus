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

    // MARK: - filterUnaliasedGroupedChildren

    func testFilter_keepsParents_dropsUnaliasedChildren() {
        let engine = SyncEngine()
        let points = [
            makePoint(id: Self.parentID),
            makePoint(id: Self.childAID, parentID: Self.parentID),
            makePoint(id: Self.childBID, parentID: Self.parentID)
        ]
        let result = engine.filterUnaliasedGroupedChildren(points, aliasByUUID: [:])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, Self.parentID)
    }

    func testFilter_keepsAliasedChildren() {
        let engine = SyncEngine()
        let points = [
            makePoint(id: Self.parentID),
            makePoint(id: Self.childAID, parentID: Self.parentID),
            makePoint(id: Self.childBID, parentID: Self.parentID)
        ]
        // Alias map is keyed by normalized id (hex-only, lowercased).
        let alias = [Self.childAID.normalized(): Self.aliasKey]
        let result = engine.filterUnaliasedGroupedChildren(points, aliasByUUID: alias)
        let ids = Set(result.map { $0.id })
        XCTAssertEqual(ids, [Self.parentID, Self.childAID])
    }

    func testFilter_ignoresUngroupedItems() {
        let engine = SyncEngine()
        let points = [
            makePoint(id: "AABB1111-2222-3333-4444-555566667777"),
            makePoint(id: "CCDD8888-9999-AAAA-BBBB-CCCCCCCCCCCC")
        ]
        let result = engine.filterUnaliasedGroupedChildren(points, aliasByUUID: [:])
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

    /// The case the development Mac actually produces, measured 2026-08-30:
    ///
    ///     parent 659A4C7F…  location=$null  crowdSourced=$null
    ///
    /// A group parent whose position is **absent** rather than stale never survives
    /// `parseDeviceArray`, so it reaches backfill as no point at all — and backfill
    /// only ever considered parents that had already parsed. The group then vanishes
    /// from both lists and its children render flat. This worked when the nesting was
    /// built, because the parent then arrived with a stale position rather than none;
    /// the fixtures kept showing it working because their parent carries a location.
    ///
    /// The parent record is real. Only its position is missing, and giving it the
    /// freshest child's position is exactly what backfill exists to do — this extends
    /// it from "stale" to "absent".
    func testBackfill_parentWithNoPositionAtAll_takesFreshestChild() throws {
        let engine = SyncEngine()
        let pid = "659A4C7F-CFED-42DC-96D4-102745AA19C2"
        let aRaw = childRaw(id: "EEEEEEEE-2222-2222-2222-222222222222",
                            parentID: pid, lat: 20.0, ts: 5000)
        let bRaw = childRaw(id: "EEEEEEEE-3333-3333-3333-333333333333",
                            parentID: pid, lat: 30.0, ts: 7000)

        // Both position fields hold Apple's "$null" placeholder, so this record yields
        // no DevicePoint at all — which is why none is passed in.
        var pRaw: [String: Any] = parentRaw(id: pid, lat: 0, ts: 0, isOld: false)
        pRaw["location"] = "$null"
        pRaw["crowdSourcedLocation"] = "$null"
        pRaw["name"] = "AirPods Pro"

        let childA = parsedDevicePoint(from: aRaw, parentID: pid)
        let childB = parsedDevicePoint(from: bRaw, parentID: pid)

        let result = engine.backfillParentLocations(
            parents: [], children: [childA, childB],
            rawDevices: [pRaw], rawItems: [aRaw, bRaw]
        ).points

        let parent = try XCTUnwrap(result.first { $0.id == pid },
                                   "the group must exist for its children to nest under")
        XCTAssertEqual(parent.latitude, 30.0, accuracy: 0.001, "freshest child")
        XCTAssertEqual(parent.name, "AirPods Pro")
    }

    /// A parent with no position and no reporting children stays absent. There is
    /// nothing to give it, and inventing a position would be worse than showing none.
    func testBackfill_parentWithNoPositionAndNoChildren_staysAbsent() {
        let engine = SyncEngine()
        let pid = "FFFFFFFF-1111-1111-1111-111111111111"
        var pRaw: [String: Any] = parentRaw(id: pid, lat: 0, ts: 0, isOld: false)
        pRaw["location"] = "$null"

        let result = engine.backfillParentLocations(
            parents: [], children: [], rawDevices: [pRaw], rawItems: []
        ).points

        XCTAssertTrue(result.isEmpty)
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
        ).points

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
        ).points
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
        ).points
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
        ).points
        XCTAssertEqual(result[0].latitude, 10.0, accuracy: 0.001)
    }
}
