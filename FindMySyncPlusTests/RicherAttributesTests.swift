import Testing
import Foundation
@testable import FindMySyncPlus

/// `richer-attributes.md` §7 — four fields chosen after measuring a real `Items.data`,
/// not before. The measurement struck two of the spec's own proposals, and two of the
/// tests here exist to keep them struck:
///
/// - `streetAddress` is the house number alone (`9`, `999`), so the address line comes
///   from `mediumAddressModern`, which Apple pre-formats.
/// - `floorLevel` read `-1` on every item measured. That is CoreLocation's "no value",
///   the same sentinel that reached Home Assistant as `altitude: -1` earlier in 1.4.6b.
///   It is deliberately not published, and `floorLevelIsNotPublished` asserts the
///   absence so a later "it's free, why not" cannot quietly reintroduce it.
@Suite("Richer attributes")
struct RicherAttributesTests {

    private func raw(
        isInaccurate: Bool? = nil,
        partName: String? = nil,
        roleName: String? = nil,
        roleEmoji: String? = nil,
        address: [String: Any]? = nil,
        floorLevel: Double? = nil
    ) -> [String: Any] {
        var location: [String: Any] = [
            "latitude": 1.0,
            "longitude": 2.0,
            "horizontalAccuracy": 3.0
        ]
        if let isInaccurate { location["isInaccurate"] = isInaccurate }
        if let floorLevel { location["floorLevel"] = floorLevel }

        var record: [String: Any] = [
            "baUUID": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            "name": "Test AirTag",
            "location": location
        ]
        if let partName { record["partInfo"] = ["name": partName, "symbol": "case", "type": 1] }
        var role: [String: Any] = [:]
        if let roleName { role["name"] = roleName }
        if let roleEmoji { role["emoji"] = roleEmoji }
        if !role.isEmpty {
            role["identifier"] = 7
            record["role"] = role
        }
        if let address { record["address"] = address }
        return record
    }

    /// The 19-sub-key shape measured 2026-08-30, trimmed to the keys that matter here.
    /// `streetAddress` is the house number on purpose — that is what the real record
    /// holds, and a fixture that made it a street line would hide why it was struck.
    private func realisticAddress() -> [String: Any] {
        [
            "streetAddress": "999",
            "streetName": "Example St",
            "locality": "Springfield",
            "stateCode": "MA",
            "countryCode": "US",
            "label": "999 Example St",
            "fullThroroughfare": "999 Example St",
            "streetAddressModern": "Example St",
            "smallAddressModern": "Example St, Springfield",
            "mediumAddressModern": "999 Example St, Springfield",
            "largeAddressModern": "999 Example St, Springfield, MA  01103",
            "mapItemFullAddress": "999 Example St, Springfield, MA  01103",
            "coarseAddressModern": "Springfield, MA"
        ]
    }

    // MARK: - Parsing

    @Test("isInaccurate is carried through")
    func carriesIsInaccurate() throws {
        let points = CacheDecryptor().parseDeviceArray([raw(isInaccurate: true)])
        let rich = try #require(points.first?.richAttributes)
        #expect(rich.isInaccurate == true)
    }

    @Test("absent isInaccurate stays absent rather than becoming false")
    func absentIsInaccurateStaysNil() throws {
        let points = CacheDecryptor().parseDeviceArray([raw()])
        let rich = try #require(points.first?.richAttributes)
        #expect(rich.isInaccurate == nil)
    }

    @Test("partInfo.name is carried through")
    func carriesPartName() throws {
        let points = CacheDecryptor().parseDeviceArray([raw(partName: "Right Bud")])
        let rich = try #require(points.first?.richAttributes)
        #expect(rich.partName == "Right Bud")
    }

    @Test("role name and emoji are carried through")
    func carriesRole() throws {
        let points = CacheDecryptor().parseDeviceArray([raw(roleName: "Backpack", roleEmoji: "🎒")])
        let rich = try #require(points.first?.richAttributes)
        #expect(rich.role == "Backpack")
        #expect(rich.roleEmoji == "🎒")
    }

    @Test("the address line comes from mediumAddressModern, not streetAddress")
    func addressUsesMediumAddressModern() throws {
        let points = CacheDecryptor().parseDeviceArray([raw(address: realisticAddress())])
        let rich = try #require(points.first?.richAttributes)
        #expect(rich.address == "999 Example St, Springfield")
        // The struck candidate. If this ever equals the house number, the wrong key
        // was read.
        #expect(rich.address != "999")
    }

    @Test("an absent address dict leaves the attribute absent")
    func absentAddressStaysNil() throws {
        let points = CacheDecryptor().parseDeviceArray([raw()])
        let rich = try #require(points.first?.richAttributes)
        #expect(rich.address == nil)
    }

    @Test("an address dict without mediumAddressModern does not fall back to a worse key")
    func addressWithoutTheChosenKeyStaysNil() throws {
        var address = realisticAddress()
        address.removeValue(forKey: "mediumAddressModern")
        let points = CacheDecryptor().parseDeviceArray([raw(address: address)])
        let rich = try #require(points.first?.richAttributes)
        #expect(rich.address == nil)
    }

    @Test("a record carrying floorLevel still parses, and carries no floor of its own")
    func floorLevelIsNotParsed() throws {
        let points = CacheDecryptor().parseDeviceArray([raw(floorLevel: -1)])
        #expect(points.count == 1)
    }
}

@Suite("Richer attributes — publishing")
@MainActor
struct RicherAttributesPublishingTests {

    private func point(
        isInaccurate: Bool? = nil,
        partName: String? = nil,
        role: String? = nil,
        roleEmoji: String? = nil,
        address: String? = nil
    ) -> DevicePoint {
        let rich = RichLocationAttributes(verticalAccuracy: nil, altitude: nil,
                                          speed: nil, course: nil,
                                          timestamp: nil,
                                          motionActivityState: nil,
                                          locationLabel: nil,
                                          isInaccurate: isInaccurate,
                                          partName: partName,
                                          role: role,
                                          roleEmoji: roleEmoji,
                                          address: address)
        return DevicePoint(id: "uuid", name: "Test AirTag",
                           latitude: 1, longitude: 2, accuracy: 3,
                           battery: nil, richAttributes: rich)
    }

    @Test("the new attributes reach the MQTT payload")
    func attributesArePublished() {
        let attrs = MQTTClient().buildAttributes(
            for: point(isInaccurate: false,
                       partName: "Case",
                       role: "Backpack",
                       roleEmoji: "🎒",
                       address: "999 Example St, Springfield"),
            iso: ISO8601DateFormatter())

        #expect(attrs["is_inaccurate"] as? Bool == false)
        #expect(attrs["part_name"] as? String == "Case")
        #expect(attrs["role"] as? String == "Backpack")
        #expect(attrs["role_emoji"] as? String == "🎒")
        #expect(attrs["address"] as? String == "999 Example St, Springfield")
    }

    @Test("absent fields publish no key at all")
    func absentFieldsPublishNothing() {
        let attrs = MQTTClient().buildAttributes(for: point(), iso: ISO8601DateFormatter())

        #expect(attrs["is_inaccurate"] == nil)
        #expect(attrs["part_name"] == nil)
        #expect(attrs["role"] == nil)
        #expect(attrs["role_emoji"] == nil)
        #expect(attrs["address"] == nil)
    }

    /// `floorLevel` measured `-1` on every item. Publishing it would repeat the
    /// `altitude: -1` defect fixed earlier this release, so it is not published at all
    /// — and this asserts the absence, because a struck field that leaves no trace is
    /// one "why not, it's free" away from coming back.
    @Test("floor_level is never published")
    func floorLevelIsNotPublished() {
        let attrs = MQTTClient().buildAttributes(for: point(), iso: ISO8601DateFormatter())
        #expect(attrs["floor_level"] == nil)
    }
}
