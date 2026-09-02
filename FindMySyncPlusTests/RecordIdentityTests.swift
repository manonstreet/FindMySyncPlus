import Testing
import Foundation
@testable import FindMySyncPlus

/// A record's id is resolved in two places — when a `DevicePoint` is built, and when one is
/// looked up again to backfill a group parent. They disagreed about precedence:
/// `parseDeviceArray` preferred `baUUID`, `backfillParentLocations` preferred `identifier`.
///
/// A record carrying both was therefore stored under one id and searched for under the
/// other, so the lookup missed, the group saw no children, and the parent kept a stale
/// position. That is issue #24's shape, and nothing in the suite could catch it because
/// neither chain was ever tested against a record carrying both fields.
@Suite("Record identity")
struct RecordIdentityTests {

    /// The case that produced the bug. `parseDeviceArray`'s chain is authoritative: a
    /// `DevicePoint`'s id *is* the app's identity for that record, so a lookup that
    /// resolves differently is searching for an id the object does not have.
    @Test("a record carrying both baUUID and identifier resolves to baUUID")
    func bothFieldsPresentPrefersBaUUID() {
        let raw: [String: Any] = [
            "baUUID": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            "identifier": "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
        ]
        #expect(CacheDecryptor.resolveID(raw) == "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    }

    @Test("the full precedence order")
    func precedence() {
        let all: [String: Any] = [
            "baUUID": "ba", "deviceDiscoveryId": "dd",
            "identifier": "id", "serialNumber": "sn"
        ]
        #expect(CacheDecryptor.resolveID(all) == "ba")

        var noBa = all; noBa["baUUID"] = "$null"
        #expect(CacheDecryptor.resolveID(noBa) == "dd")

        var noDd = noBa; noDd["deviceDiscoveryId"] = "$null"
        #expect(CacheDecryptor.resolveID(noDd) == "id")

        var noId = noDd; noId["identifier"] = "$null"
        #expect(CacheDecryptor.resolveID(noId) == "sn")
    }

    /// `$null` is Apple's absent marker in these plists, not a value.
    @Test("a $null field is skipped rather than returned")
    func nullishSkipped() {
        let raw: [String: Any] = ["baUUID": "$null", "identifier": "real"]
        #expect(CacheDecryptor.resolveID(raw) == "real")
    }

    @Test("a record with no usable id resolves to nil")
    func noIdentity() {
        #expect(CacheDecryptor.resolveID(["name": "x"]) == nil)
        #expect(CacheDecryptor.resolveID(["baUUID": "$null"]) == nil)
    }

    /// Ids are stored raw. `DeviceAlias.knownUUIDs` holds whatever form was saved, so
    /// normalizing here would change `DevicePoint.id` app-wide and silently unlink every
    /// existing alias from the device it names.
    @Test("the resolved id is returned unnormalized")
    func notNormalized() {
        let raw: [String: Any] = ["baUUID": "AA-BB-CC"]
        #expect(CacheDecryptor.resolveID(raw) == "AA-BB-CC")
    }

    /// The end the bug was actually felt at: a grouped child whose record carries both
    /// fields must still be found when the backfill looks for it.
    @Test("a child carrying both fields is matched by the group backfill")
    @MainActor
    func backfillFindsChildWithBothFields() throws {
        let engine = SyncEngine()
        let parentID = "11111111-1111-1111-1111-111111111111"
        let childBa = "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"

        // As `parseDeviceArray` would build it: keyed on baUUID.
        let child = DevicePoint(id: childBa, name: "Left Bud",
                                latitude: 10, longitude: 20, accuracy: 5,
                                battery: nil, parentID: parentID)

        // As Apple writes it: both fields, disagreeing.
        let rawItems: [[String: Any]] = [[
            "baUUID": childBa,
            "identifier": "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD",
            "location": ["timeStamp": 1_600_000_000_000.0]
        ]]
        let rawDevices: [[String: Any]] = [[
            "baUUID": parentID, "name": "AirPods Pro",
            "itemGroup": ["identifier": parentID]
        ]]

        let result = engine.backfillParentLocations(
            parents: [], children: [child], rawDevices: rawDevices, rawItems: rawItems)

        let parent = try #require(result.points.first { $0.id == parentID })
        #expect(parent.latitude == 10)
    }
}
