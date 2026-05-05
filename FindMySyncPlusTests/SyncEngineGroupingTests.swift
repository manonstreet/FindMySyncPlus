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
}
