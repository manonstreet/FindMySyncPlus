import Testing
import Foundation
@testable import FindMySyncPlus

/// The REST body had no test while being the migration path for every pre-MQTT user. The
/// payload is built by one function so its shape can be asserted without a server.
@Suite("REST device_tracker/see payload")
struct RESTPayloadTests {

    private func point(battery: Double?) -> DevicePoint {
        DevicePoint(id: "uuid", name: "Test AirTag", latitude: 37.3349, longitude: -122.009,
                    accuracy: 15, battery: battery)
    }

    private func json(for device: DevicePoint, alias: String) throws -> [String: Any] {
        let data = try JSONEncoder().encode(RESTClient.payload(for: device, alias: alias))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("the body carries exactly the fields device_tracker/see reads")
    func fieldSet() throws {
        let body = try json(for: point(battery: 0.8), alias: "wallet")
        #expect(Set(body.keys) == ["dev_id", "host_name", "mac", "gps", "gps_accuracy", "battery"])
    }

    /// `host_name` matches `dev_id` so the entity ID Home Assistant derives follows the alias.
    @Test("dev_id and host_name are both findmy_ plus the alias")
    func identity() throws {
        let body = try json(for: point(battery: nil), alias: "kitchen-keys")
        #expect(body["dev_id"] as? String == "findmy_kitchen-keys")
        #expect(body["host_name"] as? String == "findmy_kitchen-keys")
    }

    /// The MAC is what keeps the identity stable while Apple rotates UUIDs; it has to come
    /// from the alias alone.
    @Test("mac is derived from the alias, not the device")
    func macFromAliasOnly() throws {
        let one = try json(for: point(battery: nil), alias: "wallet")
        let same = try json(for: DevicePoint(id: "other-uuid", name: "Renamed", latitude: 0,
                                             longitude: 0, accuracy: 1, battery: nil),
                            alias: "wallet")
        let other = try json(for: point(battery: nil), alias: "keys")
        #expect(one["mac"] as? String == same["mac"] as? String)
        #expect(one["mac"] as? String != other["mac"] as? String)
    }

    @Test("gps is latitude then longitude, with the accuracy beside it")
    func coordinates() throws {
        let body = try json(for: point(battery: nil), alias: "wallet")
        #expect(body["gps"] as? [Double] == [37.3349, -122.009])
        #expect(body["gps_accuracy"] as? Double == 15)
    }

    @Test("battery is a whole percentage")
    func batteryPercent() throws {
        #expect(try json(for: point(battery: 0.804), alias: "a")["battery"] as? Int == 80)
        #expect(try json(for: point(battery: 0.805), alias: "a")["battery"] as? Int == 81)
        #expect(try json(for: point(battery: 1.0), alias: "a")["battery"] as? Int == 100)
    }

    /// Absent, not zero: a device with no reading must not post a permanent 0%.
    @Test("no battery reading means no battery key")
    func batteryAbsent() throws {
        let body = try json(for: point(battery: nil), alias: "wallet")
        #expect(body["battery"] == nil)
        #expect(!body.keys.contains("battery"))
    }
}
