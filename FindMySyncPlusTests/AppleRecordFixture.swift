import Foundation
@testable import FindMySyncPlus

/// Apple-shaped cache records for tests, in the shape measured off live caches.
///
/// The measurements live in the maintainer's record reference and in the demo fixture
/// generator (`tools/demo-fixtures/generate.swift`), which writes these same shapes. Building
/// from them matters for the keys nothing reads yet: a hand-written record with three keys
/// cannot catch a bug in reading a fourth. 1.4.6b's fixtures were wrong five separate ways,
/// each hiding something — no `vendorIdentifier` at all, a six-key `location` where Apple
/// writes eleven, `timeStamp` a Double where Apple writes an integer.
///
/// Every builder returns `[String: Any]`, so a test can still add or remove one key to make
/// the case it is about. The defaults are what Apple writes rather than what is convenient:
///
/// - `timeStamp` is an integer of milliseconds, boxed as `NSNumber` the way
///   `PropertyListSerialization` delivers it. The parser reads it `as? Double`, which bridges
///   from an `NSNumber` and does not from a Swift `Int` stored in `Any`. A fixture written as
///   a literal passes or fails for a reason the live path never sees.
/// - `$null` is Apple's placeholder for an absent value. Roughly half of all device records
///   carry it for `baUUID` and most for `location`. The key is present; the value says nothing.
/// - `batteryStatus` is a charging-state `String` on a device and a small `Int` ordinal on an
///   item. Same key, two meanings, and the two builders keep them apart.
enum AppleRecordFixture {

    /// Apple Park, the coordinate the demo fixtures use.
    static let latitude = 37.3349
    static let longitude = -122.0090

    private static var nowMs: Double { Date().timeIntervalSince1970 * 1000 }

    // MARK: - location

    /// The `location` dictionary: eleven keys, the same eleven `crowdSourcedLocation` uses.
    ///
    /// `floorLevel` is `-1` on every record measured, CoreLocation's "no value"; it is here so
    /// a fixture cannot make it look like a ground floor. `speed` and `course` appear only
    /// while a device is moving, so they are absent unless asked for. `verticalAccuracy` at
    /// half the horizontal is the shape of a real fix; a negative one marks the altitude
    /// invalid, which is how a network sighting reads. `positionType` is Apple's own casing.
    static func location(latitude: Double = latitude,
                         longitude: Double = longitude,
                         accuracy: Double = 15,
                         ageMinutes: Double = 2,
                         timeStampMs: Double? = nil,
                         isOld: Bool = false,
                         positionType: String = "Wifi",
                         isInaccurate: Bool = false,
                         altitude: Double = 32,
                         verticalAccuracy: Double? = nil,
                         speed: Double? = nil,
                         course: Double? = nil) -> [String: Any] {
        var location: [String: Any] = [
            "latitude": latitude,
            "longitude": longitude,
            "horizontalAccuracy": accuracy,
            "verticalAccuracy": verticalAccuracy ?? accuracy / 2,
            "altitude": altitude,
            "floorLevel": -1.0,
            "isInaccurate": isInaccurate,
            "locationFinished": true,
            "timeStamp": NSNumber(value: Int64(timeStampMs ?? (nowMs - ageMinutes * 60_000))),
            "isOld": isOld,
            "positionType": positionType
        ]
        if let speed { location["speed"] = speed }
        if let course { location["course"] = course }
        return location
    }

    /// A Find My network sighting, the shape `crowdSourcedLocation` takes: the same eleven
    /// keys, Apple's lowercase `crowdsourced`, and `-1` for altitude and its accuracy.
    static func sighting(latitude: Double = latitude,
                         longitude: Double = longitude,
                         accuracy: Double = 75.6,
                         ageMinutes: Double = 42,
                         isOld: Bool = false) -> [String: Any] {
        location(latitude: latitude, longitude: longitude, accuracy: accuracy,
                 ageMinutes: ageMinutes, isOld: isOld, positionType: "crowdsourced",
                 altitude: -1, verticalAccuracy: -1)
    }

    // MARK: - Devices.data

    /// A device record: an iPhone, a Watch, a Mac. `batteryLevel` is a real fraction and
    /// `batteryStatus` a charging state. `location` nil writes `$null`, which is what Apple
    /// writes for a device with no current position; the key is always there. `prsId` is the
    /// literal `owner` on this account's records and a DSID on a family member's copy.
    static func device(name: String = "Test iPhone",
                       baUUID: String? = "0F1E2D3C-4B5A-4697-8899-AABBCCDDEEFF",
                       deviceDiscoveryId: String? = nil,
                       location: [String: Any]? = location(),
                       crowdSourcedLocation: [String: Any]? = nil,
                       batteryLevel: Double = 0.87,
                       batteryStatus: String = "NotCharging",
                       prsId: String = "owner",
                       itemGroup: [String: Any]? = nil) -> [String: Any] {
        var device: [String: Any] = [
            "name": name,
            "baUUID": baUUID ?? "$null",
            "deviceDiscoveryId": deviceDiscoveryId ?? baUUID ?? "$null",
            "batteryLevel": batteryLevel,
            "batteryStatus": batteryStatus,
            "prsId": prsId,
            "location": location ?? "$null",
            "crowdSourcedLocation": crowdSourcedLocation ?? "$null"
        ]
        if let itemGroup { device["itemGroup"] = itemGroup }
        return device
    }

    /// The device record Apple writes for a group on Macs that embed it: an AirPods parent
    /// carrying the group dictionary under its own `baUUID`, `0.0 / Unknown` for battery, and
    /// usually no position of its own.
    static func groupParent(name: String = "AirPods Pro",
                            baUUID: String = "A1B2C3D4-1111-4A5B-9C8D-0E1F2A3B4C5D",
                            members: [String],
                            location: [String: Any]? = nil) -> [String: Any] {
        device(name: name, baUUID: baUUID, location: location,
               batteryLevel: 0.0, batteryStatus: "Unknown",
               itemGroup: group(identifier: baUUID, name: name, members: members))
    }

    // MARK: - Groups

    /// The group dictionary: ten keys, the same whether embedded in a device record or a
    /// record of its own in `ItemGroups.data`. `itemIdentifiers` is every physical piece.
    /// `groupedItemIdentifiers` is an array of arrays, one inner array per cluster of pieces
    /// in the same place; it lags the positions by about twenty minutes in both directions,
    /// and its cluster order is unstable.
    static func group(identifier: String,
                      name: String = "AirPods Pro",
                      members: [String],
                      clusters: [[String]]? = nil) -> [String: Any] {
        let grouped: [[String]] = clusters ?? (members.isEmpty ? [] : [members])
        return [
            "identifier": identifier,
            "name": name,
            "state": 129,
            "capabilities": 798,
            "itemIdentifiers": members,
            "groupedItemIdentifiers": grouped,
            "items": members,
            "groupedItems": grouped,
            "itemPairingStateMap": Dictionary(uniqueKeysWithValues: members.map { ($0, 1) }),
            "lostMetadata": "$null"
        ]
    }

    // MARK: - Items.data

    /// An item record: an AirTag, a third-party tracker, or one piece of a grouped accessory.
    /// Twenty-one keys, all present on every item measured. `batteryStatus` is the ordinal,
    /// with `1` full and `5` low on Apple hardware. `piece` names the part of a group this is
    /// (`Case`, `Left Bud`); otherwise `partInfo` is `$null`, as it is on every ungrouped item.
    /// Keys the app does not read carry a placeholder of the measured type, and
    /// `rangeDistanceInMeters` the constant `20` it always reads.
    static func item(name: String = "Keys",
                     identifier: String = "33445566-7788-49AA-BBCC-DDEEFF001122",
                     location: [String: Any]? = location(),
                     crowdSourcedLocation: [String: Any]? = nil,
                     batteryStatus: Int = 1,
                     groupIdentifier: String? = nil,
                     piece: String? = nil,
                     role: [String: Any]? = role("Keys", "🔑"),
                     address: [String: Any]? = address(),
                     productType: [String: Any] = productType(),
                     isAppleItem: Bool = true) -> [String: Any] {
        [
            "name": name,
            "identifier": identifier,
            "serialNumber": "$null",
            "groupIdentifier": groupIdentifier ?? "$null",
            "partInfo": piece.map(partInfo) ?? "$null",
            "role": role ?? "$null",
            "address": address ?? "$null",
            "productType": productType,
            "productIdentifier": 1,
            "isAppleItem": isAppleItem,
            "isAppleAudioAccessory": piece != nil,
            "isFirmwareUpdateMandatory": false,
            "batteryStatus": batteryStatus,
            "capabilities": 0,
            "location": location ?? "$null",
            "crowdSourcedLocation": crowdSourcedLocation ?? "$null",
            "lostModeMetadata": "$null",
            "owner": "$null",
            "rangeDistanceInMeters": 20,
            "safeLocations": [],
            "systemVersion": "$null"
        ]
    }

    /// The `address` dictionary in its nineteen-key shape, every key populated, as measured
    /// on every item that had one. `streetAddress` is the house number alone: that is what
    /// Apple writes, and it is why the published attribute reads `mediumAddressModern`, one of
    /// the four widths Apple pre-formats. `label` duplicates the street line and is not the
    /// `_$!<home>!$_` wrapper the friends path decodes.
    static func address(number: String = "1",
                        street: String = "Infinite Loop",
                        city: String = "Cupertino",
                        state: String = "CA",
                        zip: String = "95014",
                        county: String = "Santa Clara County") -> [String: Any] {
        [
            "streetAddress": number,
            "streetName": street,
            "locality": city,
            "administrativeArea": state,
            "subAdministrativeArea": county,
            "stateCode": state,
            "country": "United States",
            "countryCode": "US",
            "label": "\(number) \(street)",
            "fullThroroughfare": "\(number) \(street)",
            "streetAddressModern": street,
            "smallAddressModern": "\(street), \(city)",
            "mediumAddressModern": "\(number) \(street), \(city)",
            "largeAddressModern": "\(number) \(street), \(city), \(state)  \(zip)",
            "coarseAddressModern": "\(city), \(state)",
            "mapItemFullAddress": "\(number) \(street), \(city), \(state)  \(zip)",
            "formattedAddressLines": ["\(number) \(street)", "\(city), \(state)  \(zip)", "United States"],
            "areaOfInterest": [],
            "poiAddressModern": "$null"
        ]
    }

    /// The category chosen when an item was set up. Choosing *Custom Name* on the phone
    /// stores the literal string `Custom Name` here, with the typed name in the item's `name`.
    static func role(_ name: String, _ emoji: String) -> [String: Any] {
        ["name": name, "emoji": emoji, "identifier": 7]
    }

    /// Which physical piece of a grouped accessory an item is. `name` is byte-identical to the
    /// item's own name on every grouped piece measured.
    static func partInfo(_ name: String) -> [String: Any] {
        ["name": name, "symbol": "case", "type": 1]
    }

    /// `productType` as Apple writes it. `type` is an internal codename, never a model name,
    /// and `productInformation` sits here rather than at the top level, which is why the parser
    /// reads it two levels down. `76` is Apple's Bluetooth SIG company id; a third-party
    /// vendor's value is not a SIG id at all.
    static func productType(codename: String = "b389",
                            manufacturer: String = "Apple",
                            model: String = "AirTag",
                            vendorIdentifier: Int = 76,
                            productIdentifier: Int = 1) -> [String: Any] {
        [
            "type": codename,
            "productInformation": [
                "antennaPower": 7.0,
                "manufacturerName": manufacturer,
                "modelName": model,
                "productIdentifier": productIdentifier,
                "vendorIdentifier": vendorIdentifier
            ]
        ]
    }

    // MARK: - FriendCacheData.data

    /// One entry of the FMF `contacts` dictionary, which is keyed by DSID. The app reads
    /// `displayName` and falls back to `shortName`; the rest of the entry has not been measured.
    static func friendContact(displayName: String? = "Alex Example",
                              shortName: String? = "Alex") -> [String: Any] {
        var contact: [String: Any] = [:]
        if let displayName { contact["displayName"] = displayName }
        if let shortName { contact["shortName"] = shortName }
        return contact
    }

    /// The decrypted root of `FriendCacheData.data`: a `contacts` dictionary keyed by DSID.
    static func friendCache(contacts: [String: [String: Any]]) -> [String: Any] {
        ["contacts": contacts]
    }
}
