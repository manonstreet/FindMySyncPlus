import Testing
import Foundation
import CocoaMQTT
@testable import FindMySyncPlus

/// Records what would go on the wire.
///
/// `MQTTClient` published straight to a concrete `CocoaMQTT`, which a test cannot
/// build without a socket — so the publish sequences had no coverage at all and
/// "verify it against a real broker" was the only option. A protocol over
/// `publish` alone is enough to make the order, the retain flags and the empty
/// payloads ordinary assertions.
final class RecordingPublisher: MQTTPublishing {
    private(set) var messages: [CocoaMQTTMessage] = []

    func send(_ message: CocoaMQTTMessage) {
        messages.append(message)
    }

    var topics: [String] { messages.map(\.topic) }
}

@Suite("MQTT publish sequences")
@MainActor
struct MQTTPublishSequenceTests {

    private static let devId = "findmy_old-name"
    private static let prefix = "findmysyncplus/"

    // MARK: - Clearing

    /// A tombstone is defined by being empty *and* retained: an empty payload with
    /// retain off tells the broker nothing and leaves the entity in place.
    @Test("clearing publishes an empty retained message to every topic we own")
    func clearPublishesEmptyRetained() {
        let recorder = RecordingPublisher()
        MQTTClient().clearRetainedTopics(client: recorder, devId: Self.devId, prefix: Self.prefix)

        #expect(recorder.messages.count == 3)
        for message in recorder.messages {
            #expect(message.payload.isEmpty, "a tombstone must carry no payload")
            #expect(message.retained, "an unretained empty message clears nothing")
        }
    }

    /// The discovery config goes first so HA drops the entity; the attributes topic
    /// follows so the device's last latitude/longitude does not linger.
    @Test("clearing covers the tracker, the battery sensor and the attributes topic")
    func clearCoversAllThreeTopics() {
        let recorder = RecordingPublisher()
        MQTTClient().clearRetainedTopics(client: recorder, devId: Self.devId, prefix: Self.prefix)

        #expect(recorder.topics == [
            "homeassistant/device_tracker/findmy_old-name/config",
            "homeassistant/sensor/findmy_old-name_battery/config",
            "findmysyncplus/findmy_old-name/attributes"
        ])
    }

    // MARK: - Tombstone drain

    @Test("a retired dev_id has its topics cleared and is reported as cleared")
    func retiredIsCleared() {
        let recorder = RecordingPublisher()
        let cleared = MQTTClient().publishTombstones(client: recorder,
                                                     retired: [Self.devId],
                                                     liveDevIds: ["findmy_new-name"],
                                                     prefix: Self.prefix)

        #expect(cleared == [Self.devId])
        #expect(recorder.messages.count == 3)
    }

    /// Renaming a -> b -> a must not clear the entity that is live again. Nothing
    /// may reach the wire at all in that case.
    @Test("a dev_id that is live again publishes nothing")
    func liveDevIdPublishesNothing() {
        let recorder = RecordingPublisher()
        let cleared = MQTTClient().publishTombstones(client: recorder,
                                                     retired: ["findmy_case"],
                                                     liveDevIds: ["findmy_case"],
                                                     prefix: Self.prefix)

        #expect(cleared.isEmpty)
        #expect(recorder.messages.isEmpty, "a live entity must never be touched")
    }

    // MARK: - Re-registration

    /// The whole point of the action: the entity has to be removed before the new
    /// config lands, or HA treats the pair as an update, keeps the registry entry,
    /// and the stale entity ID survives.
    @Test("re-registration clears before it republishes")
    func reRegisterClearsThenPublishes() async {
        let recorder = RecordingPublisher()
        await MQTTClient().performReRegister(client: recorder,
                                             devId: Self.devId,
                                             displayName: "Case",
                                             topicPrefix: Self.prefix,
                                             delay: 0)

        #expect(recorder.messages.count == 3, "two config clears, then one config")

        let last = recorder.messages[2]
        #expect(last.topic == "homeassistant/device_tracker/findmy_old-name/config")
        #expect(!last.payload.isEmpty, "the republished config must carry the payload")
        #expect(last.retained)
    }

    /// Found by running it: re-registration was clearing the attributes topic too,
    /// so the recreated entity had no position until the next sync — up to a full
    /// sync interval of nothing.
    ///
    /// Clearing the discovery config is what makes HA drop the entity and its
    /// registry entry. The retained attributes message is independent: leave it,
    /// and HA subscribes on re-creation and restores the location immediately.
    /// Retirement still clears it, because there the position *should* not linger.
    @Test("re-registration leaves the attributes topic alone")
    func reRegisterKeepsAttributes() async {
        let recorder = RecordingPublisher()
        await MQTTClient().performReRegister(client: recorder,
                                             devId: Self.devId,
                                             displayName: "Case",
                                             topicPrefix: Self.prefix,
                                             delay: 0)

        let attributes = MQTTClient.attributesTopic(forDevId: Self.devId, prefix: Self.prefix)
        #expect(!recorder.topics.contains(attributes),
                "clearing it discards the retained position that would restore the entity")
    }

    @Test("the republished config carries the corrected entity ID")
    func reRegisterRepublishesCorrectedID() async throws {
        let recorder = RecordingPublisher()
        await MQTTClient().performReRegister(client: recorder,
                                             devId: Self.devId,
                                             displayName: "Case",
                                             topicPrefix: Self.prefix,
                                             delay: 0)

        let data = Data(try #require(recorder.messages.last).payload)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["default_entity_id"] as? String == "device_tracker.findmy_old_name")
    }

    // MARK: - Battery sensor

    private func point(battery: Double?) -> DevicePoint {
        DevicePoint(id: "uuid", name: "Test AirTag", latitude: 1, longitude: 2,
                    accuracy: 3, battery: battery)
    }

    @Test("a device with a battery reading gets a sensor, once")
    func batterySensorPublishedOnce() {
        let recorder = RecordingPublisher()
        let client = MQTTClient()

        client.publishBatterySensorIfNeeded(client: recorder, device: point(battery: 0.8),
                                            devId: Self.devId, displayName: "Case",
                                            prefix: Self.prefix)
        client.publishBatterySensorIfNeeded(client: recorder, device: point(battery: 0.8),
                                            devId: Self.devId, displayName: "Case",
                                            prefix: Self.prefix)

        #expect(recorder.messages.count == 1, "discovery is once per session, not per sync")
        #expect(recorder.topics == ["homeassistant/sensor/findmy_old-name_battery/config"])
    }

    /// A sensor with no value shows as `unknown` in HA and clutters the device card.
    @Test("a device with no battery reading gets no sensor")
    func noBatteryNoSensor() {
        let recorder = RecordingPublisher()
        MQTTClient().publishBatterySensorIfNeeded(client: recorder, device: point(battery: nil),
                                                  devId: Self.devId, displayName: "Case",
                                                  prefix: Self.prefix)

        #expect(recorder.messages.isEmpty)
    }
}
