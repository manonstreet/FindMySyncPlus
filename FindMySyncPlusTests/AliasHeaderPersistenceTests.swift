import Testing
import Foundation
@testable import FindMySyncPlus

/// A header for an unaliased group was drawn from the **live** grouping only, because
/// `parentAlias` is written just when *both* ends are aliased — so an unaliased group
/// had nothing persisted to read. That made the header the one part of the Aliases list
/// that needed a device to have reported this cycle, in a list whose whole premise is
/// that it is config and survives things being offline.
///
/// Two states exposed it. Delete an aliased group and its children keep a `parentAlias`
/// naming a row that no longer exists, so they fall through to the live branch. Alias a
/// group that has never reported and the children have no stored value at all. Both went
/// flat until the accessory next reported.
///
/// `parentGroupID` and `parentGroupName` persist the group's own identity on the child,
/// so a header can be drawn with nothing live at all — the same contract `parentAlias`
/// already has, applied to the case it could not reach.
@Suite("Alias headers without a live run")
struct AliasHeaderPersistenceTests {

    private static let groupID = "659a4c7fcfed42dc96d4102745aa19c2"

    private func child(_ name: String,
                       parent: String? = nil,
                       groupID: String? = groupID,
                       groupName: String? = "AirPods Pro") -> DeviceAlias {
        DeviceAlias(alias: name, tracked: true, knownUUIDs: ["\(name)-uuid"],
                    lastSeenName: name, parentAlias: parent,
                    parentGroupID: groupID, parentGroupName: groupName)
    }

    /// The parent's own row: it owns the group id among its UUIDs.
    private func parentRow(_ name: String) -> DeviceAlias {
        DeviceAlias(alias: name, tracked: true, knownUUIDs: [Self.groupID],
                    lastSeenName: "AirPods Pro")
    }

    @Test("children nest under a header with no live grouping at all")
    func headerFromPersistedIdentityAlone() throws {
        let rows = [child("case"), child("left-bud"), child("right-bud")]
        let partition = AliasPartition(rows, liveGroups: [:])

        let header = try #require(partition.headers.first)
        #expect(partition.headers.count == 1)
        #expect(header.name == "AirPods Pro")
        #expect(partition.children(ofHeader: header.id).count == 3)
        #expect(partition.topLevel.isEmpty)
    }

    /// The delete case. The children keep a `parentAlias` naming a row that is gone;
    /// that pointer is dangling, but the group identity beside it is not.
    @Test("deleting the group's alias leaves a header rather than flattening")
    func danglingParentAliasStillDrawsAHeader() throws {
        let rows = [child("case", parent: "airpods"),
                    child("left-bud", parent: "airpods")]
        let partition = AliasPartition(rows, liveGroups: [:])

        let header = try #require(partition.headers.first)
        #expect(partition.children(ofHeader: header.id).count == 2)
        #expect(partition.topLevel.isEmpty)
    }

    /// The guard that matters: a header and a real row must never both be drawn for one
    /// group. Offline, `liveGroups` is empty, so this can only be caught by matching the
    /// persisted group id against the parent row's own UUIDs.
    @Test("an aliased parent still wins over a header when nothing reported")
    func aliasedParentSupersedesThePersistedHeader() {
        let rows = [parentRow("airpods"),
                    child("case", parent: "airpods"),
                    child("left-bud", parent: "airpods")]
        let partition = AliasPartition(rows, liveGroups: [:])

        #expect(partition.headers.isEmpty)
        #expect(partition.children(of: "airpods").count == 2)
        #expect(partition.topLevel.map(\.alias) == ["airpods"])
    }

    /// Aliasing a group *after* its children leaves them with the group id but no
    /// `parentAlias` — the join was observed when the group had no alias to record.
    /// They must nest under the real row: a header beside it would draw the same group
    /// twice, and top level would lose the nesting the user just created.
    ///
    /// This one was wrong first. The persisted-header branch correctly declined (the
    /// parent owns the id), but nothing then claimed the children and they fell to top
    /// level. The gap only exists offline, which is exactly where it would not have been
    /// noticed.
    @Test("children nest under a group aliased after them, with nothing live")
    func offlineAliasedParentWithNoStoredParentAlias() {
        let rows = [parentRow("airpods"), child("case"), child("left-bud")]
        let partition = AliasPartition(rows, liveGroups: [:])

        #expect(partition.headers.isEmpty)
        #expect(partition.topLevel.map(\.alias) == ["airpods"])
        #expect(partition.children(of: "airpods").map(\.alias) == ["case", "left-bud"])
    }

    /// Live grouping still wins when it is present — it carries Apple's current name,
    /// and a rename should not be masked by a stale persisted copy.
    @Test("a live grouping takes precedence over the persisted name")
    func liveGroupingWinsOnName() throws {
        let rows = [child("case", groupName: "Old Name")]
        let partition = AliasPartition(
            rows, liveGroups: ["case": (id: Self.groupID, name: "AirPods Pro")])

        let header = try #require(partition.headers.first)
        #expect(header.name == "AirPods Pro")
    }

    @Test("a child with no group identity at all stays top-level")
    func noGroupIdentityStaysFlat() {
        let rows = [child("keys", groupID: nil, groupName: nil)]
        let partition = AliasPartition(rows, liveGroups: [:])

        #expect(partition.headers.isEmpty)
        #expect(partition.topLevel.map(\.alias) == ["keys"])
    }

    /// Absent keys must decode, because every alias already on disk lacks them.
    @Test("an alias stored before these fields existed still decodes")
    func decodesWithoutTheNewKeys() throws {
        let json = """
        {"alias":"case","tracked":true,"knownUUIDs":["abc"],"lastSeenName":"Case"}
        """
        let decoded = try JSONDecoder().decode(DeviceAlias.self, from: Data(json.utf8))

        #expect(decoded.parentGroupID == nil)
        #expect(decoded.parentGroupName == nil)
        #expect(decoded.alias == "case")
    }

    @Test("the new fields survive a round trip")
    func roundTrips() throws {
        let original = child("case", parent: "airpods")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DeviceAlias.self, from: data)

        #expect(decoded.parentGroupID == Self.groupID)
        #expect(decoded.parentGroupName == "AirPods Pro")
    }
}
