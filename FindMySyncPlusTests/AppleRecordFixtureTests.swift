import Testing
import Foundation
@testable import FindMySyncPlus

/// The fixture builder is only worth having if what it builds goes through the real parsers
/// the way a live record does. These prove the shapes, not the parsers: every value asserted
/// here is a default the builder chose.
@Suite("Apple record fixtures")
struct AppleRecordFixtureTests {

    private let decryptor = CacheDecryptor()

    private static let measuredItemKeys: Set<String> = [
        "address", "batteryStatus", "capabilities", "crowdSourcedLocation", "groupIdentifier",
        "identifier", "isAppleAudioAccessory", "isAppleItem", "isFirmwareUpdateMandatory",
        "location", "lostModeMetadata", "name", "owner", "partInfo", "productIdentifier",
        "productType", "rangeDistanceInMeters", "role", "safeLocations", "serialNumber",
        "systemVersion"
    ]

    private static let measuredLocationKeys: Set<String> = [
        "latitude", "longitude", "horizontalAccuracy", "verticalAccuracy", "altitude",
        "floorLevel", "isInaccurate", "locationFinished", "timeStamp", "isOld", "positionType"
    ]

    @Test("a device parses with its position, battery and charging state")
    func deviceParses() throws {
        let points = decryptor.parseDeviceArray([
            AppleRecordFixture.device(batteryLevel: 0.42, batteryStatus: "Charging")
        ])
        let point = try #require(points.first)
        #expect(points.count == 1)
        #expect(point.id == "0F1E2D3C-4B5A-4697-8899-AABBCCDDEEFF")
        #expect(point.name == "Test iPhone")
        #expect(point.latitude == AppleRecordFixture.latitude)
        #expect(point.longitude == AppleRecordFixture.longitude)
        #expect(point.accuracy == 15)
        #expect(point.battery == 0.42)
        #expect(point.chargingState == "Charging")
        #expect(point.batteryStatusCode == nil, "a device carries no ordinal")
        #expect(point.prsId == "owner")

        let rich = try #require(point.richAttributes)
        #expect(rich.positionType == "Wifi")
        #expect(rich.isOld == false)
        #expect(rich.altitude == 32)
        let age = try #require(rich.timestamp).timeIntervalSinceNow
        #expect(age < -110 && age > -130, "two minutes old, from an integer of milliseconds")
    }

    @Test("a device with no position is skipped, as Apple's $null is")
    func nullLocationSkipped() {
        let points = decryptor.parseDeviceArray([AppleRecordFixture.device(location: nil)])
        #expect(points.isEmpty)
    }

    @Test("a network sighting rescues a device with no position of its own")
    func sightingRescues() throws {
        let points = decryptor.parseDeviceArray([
            AppleRecordFixture.device(location: nil, crowdSourcedLocation: AppleRecordFixture.sighting())
        ])
        let rich = try #require(points.first?.richAttributes)
        #expect(rich.positionType == "crowdsourced")
        #expect(rich.altitude == nil, "a negative vertical accuracy marks the altitude invalid")
    }

    @Test("an item parses with its vendor, address, role and battery ordinal")
    func itemParses() throws {
        let points = decryptor.parseDeviceArray([AppleRecordFixture.item(batteryStatus: 5)])
        let point = try #require(points.first)
        #expect(point.id == "33445566-7788-49AA-BBCC-DDEEFF001122")
        #expect(point.vendorIdentifier == 76)
        #expect(point.batteryStatusCode == 5)
        #expect(point.battery == nil, "an item carries no percentage")
        #expect(point.chargingState == nil)

        let rich = try #require(point.richAttributes)
        #expect(rich.address == "1 Infinite Loop, Cupertino")
        #expect(rich.role == "Keys")
        #expect(rich.roleEmoji == "🔑")
    }

    @Test("an item carries the twenty-one measured keys, and a location the eleven")
    func measuredKeySets() {
        #expect(Set(AppleRecordFixture.item().keys) == Self.measuredItemKeys)
        #expect(Set(AppleRecordFixture.location().keys) == Self.measuredLocationKeys)
        #expect(Set(AppleRecordFixture.sighting().keys) == Self.measuredLocationKeys)
        #expect(AppleRecordFixture.address().count == 19)
        #expect(AppleRecordFixture.group(identifier: "g", members: ["a"]).count == 10)
    }

    /// The trap the builder exists to keep out of fixtures. An integer in a plist arrives as
    /// an `NSNumber`, which bridges to `Double`; a Swift `Int` stored in `Any` does not.
    @Test("timeStamp is an integer that still reads as a Double")
    func timeStampBridges() throws {
        let location = AppleRecordFixture.location(timeStampMs: 1_700_000_000_000)
        #expect(location["timeStamp"] is NSNumber)
        #expect(location["timeStamp"] as? Double == 1_700_000_000_000)

        let literal: [String: Any] = ["timeStamp": Int(1_700_000_000_000)]
        #expect(literal["timeStamp"] as? Double == nil,
                "a literal Int would silently drop the timestamp the parser reads")
    }

    @Test("a group parent nests the pieces that name it")
    @MainActor
    func groupParentNests() throws {
        let caseID = "55667788-99AA-4BCC-DDEE-FF0011223344"
        let parent = AppleRecordFixture.groupParent(members: [caseID])
        let parentID = try #require(parent["baUUID"] as? String)

        let engine = SyncEngine()
        let parentIDs = engine.buildGroupParentIDs(rawDevices: [parent])
        #expect(parentIDs[parentID] == parentID)

        let pieces = decryptor.parseDeviceArray(
            [AppleRecordFixture.item(name: "Case", identifier: caseID,
                                     groupIdentifier: parentID, piece: "Case")],
            groupParentIDs: parentIDs)
        #expect(pieces.first?.parentID == parentID)
    }

    @Test("a group record adapts to a parent, and an empty one is nothing")
    @MainActor
    func groupRecordAdapts() {
        let engine = SyncEngine()
        let adapted = engine.groupParentRecords(
            fromItemGroups: [AppleRecordFixture.group(identifier: "g1", members: ["a", "b"]),
                             AppleRecordFixture.group(identifier: "g2", members: [])],
            existingParentIDs: [])
        #expect(adapted.count == 1)
        #expect(adapted.first?["baUUID"] as? String == "g1")
    }
}
