import Testing
import Foundation
@testable import FindMySyncPlus

/// Home Assistant removed the `object_id` discovery option in Core 2026.4 after
/// deprecating it in 2025.10; it is now silently ignored. With no entity-ID hint
/// HA falls back to slugify("{device name} {entity name}"), which turned
/// `findmy_ohrapfel-case` into `device_tracker.findmysync_case` (issue #22, and
/// reported earlier on #16 and wrongly answered as working-as-designed). The
/// replacement is `default_entity_id`, which unlike `object_id` carries the
/// domain prefix.
///
/// These are the first assertions ever made against this payload — it was a
/// dictionary literal inside `post()`, behind a connected-socket guard, so its
/// contents were unreachable from a test. That is why the rot went unnoticed for
/// four months.
@Suite("MQTT discovery payload")
struct MQTTDiscoveryTests {

    private static let devId = "findmy_ohrapfel-case"

    private func payload() -> [String: Any] {
        MQTTClient.discoveryPayload(devId: Self.devId,
                                    displayName: "Case",
                                    topicPrefix: "findmysyncplus/")
    }

    @Test("publishes default_entity_id with the device_tracker domain prefix")
    func publishesDefaultEntityID() {
        #expect(payload()["default_entity_id"] as? String == "device_tracker.findmy_ohrapfel_case")
    }

    /// The identity key for HA's entity registry. If this is ever slugified to
    /// match default_entity_id, every existing user's entities are re-registered
    /// as duplicates and the originals are orphaned. The inconsistency between
    /// the two keys is deliberate.
    @Test("leaves unique_id byte-identical, hyphens and all")
    func uniqueIDUnchanged() {
        #expect(payload()["unique_id"] as? String == "findmy_ohrapfel-case")
    }

    /// Ignored on HA >= 2026.4 and explicitly documented as unable to break
    /// discovery, but still honoured on HA < 2025.10. Costs one key.
    @Test("keeps object_id for older Home Assistant")
    func keepsObjectID() {
        #expect(payload()["object_id"] as? String == "findmy_ohrapfel-case")
    }

    /// An MQTT topic, where hyphens are legal. Slugging it would strand the
    /// retained attribute value at the old topic.
    @Test("keeps the hyphen in the attributes topic")
    func attributesTopicKeepsHyphen() {
        #expect(payload()["json_attributes_topic"] as? String
                == "findmysyncplus/findmy_ohrapfel-case/attributes")
    }

    @Test("names the entity from the Find My display name")
    func usesDisplayName() {
        #expect(payload()["name"] as? String == "Case")
    }

    @Test("declares gps as the source type")
    func sourceTypeIsGPS() {
        #expect(payload()["source_type"] as? String == "gps")
    }

    /// Unknown keys in the nested device block are rejected outright by HA,
    /// unlike unknown top-level keys. Pinning the shape stops anything being
    /// added here casually.
    @Test("device block carries exactly the four documented keys")
    func deviceBlockShape() throws {
        let device = try #require(payload()["device"] as? [String: Any])
        #expect(Set(device.keys) == ["identifiers", "name", "manufacturer", "model"])
        #expect(device["identifiers"] as? [String] == ["findmysyncplus"])
        #expect(device["name"] as? String == "FindMySync+")
    }

    /// No state_topic on purpose: HA derives tracker state from the lat/lon in
    /// json_attributes_topic, and publishing state on every sync caused
    /// home -> not_home -> home flapping that reset zone-duration counters
    /// (commit 4c28f0d).
    @Test("omits state_topic")
    func omitsStateTopic() {
        #expect(payload()["state_topic"] == nil)
    }

    @Test("the payload serialises to JSON")
    func serialisable() {
        #expect(JSONSerialization.isValidJSONObject(payload()))
    }

    @Test("builds the discovery topic in HA's namespace")
    func discoveryTopic() {
        #expect(MQTTClient.discoveryTopic(forDevId: Self.devId)
                == "homeassistant/device_tracker/findmy_ohrapfel-case/config")
    }
}
