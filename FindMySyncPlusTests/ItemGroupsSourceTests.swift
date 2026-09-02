import Testing
import Foundation
@testable import FindMySyncPlus

/// `misc.md` §6.2 — a group is described either by an embedded `itemGroup` on a device
/// record or by a standalone record in `ItemGroups.data`, and the two carry the **same
/// identity**: the development Mac's parent `baUUID` and mini's `ItemGroups`
/// `identifier` measured byte-identical for the same physical AirPods.
///
/// So this is not "synthesize a parent" — the framing that got §7 deferred and was
/// wrong about its own subject. It is reading a second file Apple writes and adapting
/// its records into the shape the parent-handling code already understands, so
/// `buildGroupParentIDs`, `revivedParents` and `backfillParentLocations` need no
/// changes at all.
///
/// Both guards below come from measurement, not caution: mini carries a real group and
/// an empty one.
@Suite("ItemGroups.data as a group source")
@MainActor
struct ItemGroupsSourceTests {

    private static let groupID = "659A4C7F-CFED-42DC-96D4-102745AA19C2"
    private static let emptyGroupID = "4A978914-0000-4000-8000-000000000000"
    private static let caseID = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    private static let leftID = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"

    /// The ten-key shape measured on a live cache, reproduced whole — a fixture that is
    /// a subset of the real record is how this release lost time five separate times.
    private func groupRecord(id: String, name: String, members: [String]) -> [String: Any] {
        [
            "identifier": id,
            "name": name,
            "state": 129,
            "capabilities": 798,
            "itemIdentifiers": members,
            "groupedItemIdentifiers": members.isEmpty ? [] : [members[0]],
            "items": members,
            "groupedItems": members.isEmpty ? [] : [members[0]],
            "itemPairingStateMap": members.isEmpty ? [:] : [members[0]: 1],
            "lostMetadata": "$null"
        ]
    }

    private func child(id: String, parentID: String) -> DevicePoint {
        DevicePoint(id: id, name: "Child", latitude: 10, longitude: 20, accuracy: 5,
                    battery: nil, parentID: parentID)
    }

    // MARK: - The adapter

    @Test("an ItemGroups record becomes a parent record the existing code recognizes")
    func adaptsToAParentRecord() throws {
        let engine = SyncEngine()
        let adapted = engine.groupParentRecords(
            fromItemGroups: [groupRecord(id: Self.groupID, name: "AirPods Pro",
                                         members: [Self.caseID, Self.leftID])],
            existingParentIDs: [])

        let record = try #require(adapted.first)
        #expect(adapted.count == 1)
        // The three grouping functions all key off these two things.
        #expect(record["baUUID"] as? String == Self.groupID)
        #expect(record["itemGroup"] is [String: Any])
        #expect(record["name"] as? String == "AirPods Pro")
    }

    @Test("an empty group never becomes a parent")
    func emptyGroupIsSkipped() {
        let engine = SyncEngine()
        let adapted = engine.groupParentRecords(
            fromItemGroups: [groupRecord(id: Self.emptyGroupID, name: "Empty Group", members: [])],
            existingParentIDs: [])

        #expect(adapted.isEmpty)
    }

    @Test("a real group and an empty one together yield only the real one")
    func minisTwoRecords() throws {
        let engine = SyncEngine()
        let adapted = engine.groupParentRecords(
            fromItemGroups: [
                groupRecord(id: Self.groupID, name: "AirPods Pro", members: [Self.caseID, Self.leftID]),
                groupRecord(id: Self.emptyGroupID, name: "Empty Group", members: [])
            ],
            existingParentIDs: [])

        #expect(adapted.count == 1)
        #expect(adapted.first?["baUUID"] as? String == Self.groupID)
    }

    /// The ids are byte-identical across machines, so keying on the id dedups naturally
    /// — no name matching, which would be a guess.
    @Test("a group already described by a device record is not added twice")
    func dedupsAgainstDeviceDescribedGroups() {
        let engine = SyncEngine()
        let adapted = engine.groupParentRecords(
            fromItemGroups: [groupRecord(id: Self.groupID, name: "AirPods Pro",
                                         members: [Self.caseID, Self.leftID])],
            existingParentIDs: [Self.groupID])

        #expect(adapted.isEmpty)
    }

    @Test("a record with no identifier is skipped rather than given a placeholder")
    func missingIdentifierIsSkipped() {
        let engine = SyncEngine()
        var record = groupRecord(id: Self.groupID, name: "AirPods Pro", members: [Self.caseID])
        record["identifier"] = "$null"
        let adapted = engine.groupParentRecords(fromItemGroups: [record], existingParentIDs: [])

        #expect(adapted.isEmpty)
    }

    // MARK: - End to end, through the path that already ships

    /// Case 3 in §6.2's table: no device record at all, position from the freshest
    /// child. It reuses case 2's rule exactly, which is the point of the adapter.
    @Test("a group with no device record is revived from its freshest child")
    func groupWithNoDeviceRecordIsRevived() throws {
        let engine = SyncEngine()
        let adapted = engine.groupParentRecords(
            fromItemGroups: [groupRecord(id: Self.groupID, name: "AirPods Pro",
                                         members: [Self.caseID, Self.leftID])],
            existingParentIDs: [])

        let rawItems: [[String: Any]] = [
            ["identifier": Self.caseID, "location": ["timeStamp": 1_600_000_000_000.0]],
            ["identifier": Self.leftID, "location": ["timeStamp": 1_600_000_500_000.0]]
        ]

        let result = engine.backfillParentLocations(
            parents: [],
            children: [child(id: Self.caseID, parentID: Self.groupID),
                       child(id: Self.leftID, parentID: Self.groupID)],
            rawDevices: adapted,
            rawItems: rawItems).points

        let parent = try #require(result.first { $0.id == Self.groupID })
        #expect(parent.name == "AirPods Pro")
        #expect(parent.latitude == 10)
    }

    /// "No reporting child means no position, so the group does not appear — inventing
    /// one would be worse than showing none."
    @Test("a group whose children are all silent produces nothing")
    func groupWithNoReportingChildProducesNothing() {
        let engine = SyncEngine()
        let adapted = engine.groupParentRecords(
            fromItemGroups: [groupRecord(id: Self.groupID, name: "AirPods Pro",
                                         members: [Self.caseID])],
            existingParentIDs: [])

        let result = engine.backfillParentLocations(
            parents: [], children: [], rawDevices: adapted, rawItems: []).points

        #expect(result.isEmpty)
    }
}
