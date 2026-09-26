import Foundation
import Testing
@testable import FindMySyncPlus

/// `DeviceAlias.decodeStored`: one unreadable entry costs that entry, not the list.
struct StoredAliasDecodeTests {

    private func json(_ aliases: [DeviceAlias]) throws -> String {
        let data = try JSONEncoder().encode(aliases)
        return try #require(String(data: data, encoding: .utf8))
    }

    private let kitchen = DeviceAlias(alias: "kitchen_tag", tracked: true,
                                      knownUUIDs: ["UUID-A"], lastSeenName: "Test AirTag")
    private let keys = DeviceAlias(alias: "keys", tracked: false,
                                   knownUUIDs: ["UUID-B", "UUID-C"], lastSeenName: nil,
                                   parentAlias: "bag", parentGroupID: "G-1", parentGroupName: "Test Bag")

    @Test func roundTripsAWellFormedList() throws {
        let result = DeviceAlias.decodeStored(try json([kitchen, keys]))
        #expect(result == StoredAliasDecode(aliases: [kitchen, keys], dropped: 0))
    }

    @Test func emptyTextIsAnEmptyList() {
        #expect(DeviceAlias.decodeStored("") == StoredAliasDecode(aliases: [], dropped: 0))
        #expect(DeviceAlias.decodeStored("[]") == StoredAliasDecode(aliases: [], dropped: 0))
    }

    @Test func aMalformedEntryCostsOnlyThatEntry() throws {
        let good = try json([kitchen, keys])
        // The middle entry is missing the required `tracked` and `knownUUIDs`.
        let mixed = good.replacingOccurrences(of: "},{", with: "},{\"alias\":\"broken\"},{")
        let result = DeviceAlias.decodeStored(mixed)
        #expect(result.aliases == [kitchen, keys])
        #expect(result.dropped == 1)
        #expect(result.unreadable == nil)
    }

    @Test func bareValuesInTheListAreDroppedNotFatal() throws {
        let good = try json([kitchen])
        let mixed = "[\"just a string\", 42, " + good.dropFirst()
        let result = DeviceAlias.decodeStored(mixed)
        #expect(result.aliases == [kitchen])
        #expect(result.dropped == 2)
    }

    @Test func textThatIsNotAJSONArrayIsUnreadable() {
        let notJSON = DeviceAlias.decodeStored("{not json")
        #expect(notJSON.aliases.isEmpty)
        #expect(notJSON.unreadable != nil)

        let anObject = DeviceAlias.decodeStored("{\"alias\":\"kitchen_tag\"}")
        #expect(anObject.aliases.isEmpty)
        #expect(anObject.unreadable == "not a JSON array")
    }
}
