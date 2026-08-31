import Foundation

struct DevicePoint: Sendable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
    let accuracy: Double
    let battery: Double?
    /// `Items.data` battery ordinal, passed through unmodified. Its meaning varies by
    /// manufacturer and is deliberately not normalized — see `BatteryParsingTests`.
    let batteryStatusCode: Int?
    /// `Devices.data` charging state ("Charging" / "NotCharging" / "Unknown").
    let chargingState: String?
    /// Bluetooth SIG company ID from `productType.productInformation`. Apple is 76;
    /// third-party values are not SIG ids at all (a Pebblebee reads -1163068817), which
    /// is why it is only trusted as an Apple whitelist.
    let vendorIdentifier: Int?
    let prsId: String?     // person ID (base64 DSID); "owner" for self, DSID for family devices
    let richAttributes: RichLocationAttributes?
    let parentID: String?  // non-nil for grouped children (e.g. AirPods bud → its case/group baUUID)

    // swiftlint:disable:next line_length
    init(id: String, name: String, latitude: Double, longitude: Double, accuracy: Double, battery: Double?, batteryStatusCode: Int? = nil, chargingState: String? = nil, vendorIdentifier: Int? = nil, prsId: String? = nil, richAttributes: RichLocationAttributes? = nil, parentID: String? = nil) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
        self.battery = battery
        self.batteryStatusCode = batteryStatusCode
        self.chargingState = chargingState
        self.vendorIdentifier = vendorIdentifier
        self.prsId = prsId
        self.richAttributes = richAttributes
        self.parentID = parentID
    }

    /// Apple's Bluetooth SIG company ID.
    static let appleVendorIdentifier = 76
    /// The one `batteryStatus` ordinal correlated with a real Find My low-battery
    /// banner, against four observations of 1 on healthy Apple hardware. 2 through 4
    /// are unobserved, so the flag warns late at worst and never falsely.
    static let appleLowBatteryOrdinal = 5

    /// Whether this is a low battery, or `nil` when no such claim can be made.
    ///
    /// Scoped to Apple deliberately. Third-party ordinals are vendor-defined and
    /// cannot be reconciled — a Sitecom reads 0 and a World Tag 100 on the same
    /// field — so there is no threshold to be conservative *about*, and publishing a
    /// flag for them would be a claim rather than a reading. `nil` for them, and for
    /// anything with no ordinal at all, including every `Devices.data` entry.
    var isBatteryLow: Bool? {
        guard let code = batteryStatusCode,
              vendorIdentifier == Self.appleVendorIdentifier else { return nil }
        return code == Self.appleLowBatteryOrdinal
    }

    func with(name: String? = nil, richAttributes: RichLocationAttributes? = nil) -> DevicePoint {
        DevicePoint(id: id, name: name ?? self.name,
                    latitude: latitude, longitude: longitude,
                    accuracy: accuracy, battery: battery,
                    batteryStatusCode: batteryStatusCode, chargingState: chargingState,
                    vendorIdentifier: vendorIdentifier,
                    prsId: prsId, richAttributes: richAttributes ?? self.richAttributes,
                    parentID: parentID)
    }
}
