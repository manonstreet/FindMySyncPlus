import Foundation

struct DevicePoint: Sendable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
    let accuracy: Double
    let battery: Double?
    let prsId: String?     // person ID (base64 DSID); "owner" for self, DSID for family devices
    let richAttributes: RichLocationAttributes?

    // swiftlint:disable:next line_length
    init(id: String, name: String, latitude: Double, longitude: Double, accuracy: Double, battery: Double?, prsId: String? = nil, richAttributes: RichLocationAttributes? = nil) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
        self.battery = battery
        self.prsId = prsId
        self.richAttributes = richAttributes
    }
}
