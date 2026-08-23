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

/// Renaming, deleting or untracking an alias changes `devId`, so the app
/// publishes to a new pair of topics and the old pair stays retained on the
/// broker forever — HA keeps showing an entity the user cannot remove, and the
/// attributes topic keeps the device's last latitude/longitude parked there.
///
/// The app retires the old devId at the moment the alias changes, so there is no
/// ownership question and no broker read: it knows exactly which topics it
/// published. An earlier design diffed the broker's retained configs against the
/// live alias set instead, which could not tell one install's entities from
/// another's — two Macs on one broker would have deleted each other's.
@Suite("Discovery tombstones")
struct DiscoveryTombstoneTests {

    @Test("publishes a tombstone for a retired ID")
    func retiredIDIsTombstoned() {
        let result = MQTTClient.tombstonesToPublish(
            retired: ["findmy_old-name"],
            liveDevIds: ["findmy_new-name"]
        )
        #expect(result == ["findmy_old-name"])
    }

    /// Renaming a -> b -> a must not clear the entity that is live again.
    /// Without this, a round-trip rename deletes the user's working entity.
    @Test("never tombstones an ID that is live again")
    func liveIDIsNeverTombstoned() {
        let result = MQTTClient.tombstonesToPublish(
            retired: ["findmy_case"],
            liveDevIds: ["findmy_case"]
        )
        #expect(result.isEmpty, "a devId in use must never be cleared")
    }

    @Test("deduplicates repeated retirements")
    func deduplicates() {
        let result = MQTTClient.tombstonesToPublish(
            retired: ["findmy_a", "findmy_a", "findmy_b"],
            liveDevIds: []
        )
        #expect(result == ["findmy_a", "findmy_b"])
    }

    @Test("returns nothing when there is nothing retired")
    func emptyIsEmpty() {
        #expect(MQTTClient.tombstonesToPublish(retired: [], liveDevIds: ["findmy_a"]).isEmpty)
    }

    @Test("builds the attributes topic for clearing")
    func buildsAttributesTopic() {
        #expect(MQTTClient.attributesTopic(forDevId: "findmy_a-b", prefix: "findmysyncplus/")
                == "findmysyncplus/findmy_a-b/attributes")
    }
}
