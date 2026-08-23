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
/// The app has no record of historical devIds once an alias is gone, so orphans
/// are found by diffing the broker's retained configs against the live alias set
/// rather than by replaying a list we never kept.
@Suite("Orphan reconciliation")
struct OrphanReconciliationTests {

    private func ourConfig(_ devId: String) -> [String: Any] {
        ["unique_id": devId,
         "device": ["identifiers": ["findmysyncplus"], "name": "FindMySync+"]]
    }

    private func topic(_ devId: String) -> String {
        "homeassistant/device_tracker/\(devId)/config"
    }

    @Test("an entity of ours with no live alias is an orphan")
    func findsOrphan() {
        let result = MQTTClient.orphanedDevIds(
            retainedConfigs: [topic("findmy_old-name"): ourConfig("findmy_old-name")],
            liveDevIds: ["findmy_current"]
        )
        #expect(result == ["findmy_old-name"])
    }

    /// Renaming a -> b -> a must not clear the entity that is live again.
    @Test("never returns a devId that is live")
    func liveIsNeverOrphaned() {
        let result = MQTTClient.orphanedDevIds(
            retainedConfigs: [topic("findmy_case"): ourConfig("findmy_case")],
            liveDevIds: ["findmy_case"]
        )
        #expect(result.isEmpty, "a live devId must never be a deletion candidate")
    }

    /// Other integrations share the discovery namespace. Deleting someone else's
    /// entity would be far worse than the bug being fixed, so ownership is tested
    /// on our device identifier, not on the topic name.
    @Test("ignores discovery configs that are not ours")
    func ignoresForeignConfigs() {
        let foreign: [String: Any] = ["unique_id": "zigbee_thing",
                                      "device": ["identifiers": ["zigbee2mqtt"]]]
        let result = MQTTClient.orphanedDevIds(
            retainedConfigs: ["homeassistant/device_tracker/zigbee_thing/config": foreign],
            liveDevIds: ["findmy_case"]
        )
        #expect(result.isEmpty)
    }

    /// The catastrophic case. An empty alias set means settings have not loaded
    /// or the user is mid-setup — not that every entity is garbage.
    @Test("refuses to reconcile against an empty alias set")
    func emptyLiveSetDeletesNothing() {
        let result = MQTTClient.orphanedDevIds(
            retainedConfigs: [topic("findmy_a"): ourConfig("findmy_a"),
                              topic("findmy_b"): ourConfig("findmy_b")],
            liveDevIds: []
        )
        #expect(result.isEmpty, "an empty live set must never mean delete everything")
    }

    @Test("survives a malformed payload")
    func malformedPayloadIgnored() {
        let result = MQTTClient.orphanedDevIds(
            retainedConfigs: [topic("findmy_x"): ["unique_id": "findmy_x"]],
            liveDevIds: ["findmy_live"]
        )
        #expect(result.isEmpty, "no device block means we cannot claim ownership")
    }

    @Test("parses the devId out of a discovery topic")
    func parsesDevIdFromTopic() {
        #expect(MQTTClient.devId(fromDiscoveryTopic: topic("findmy_a-b")) == "findmy_a-b")
        #expect(MQTTClient.devId(fromDiscoveryTopic: "homeassistant/sensor/x/config") == nil)
        #expect(MQTTClient.devId(fromDiscoveryTopic: "nonsense") == nil)
    }

    @Test("builds the attributes topic for clearing")
    func buildsAttributesTopic() {
        #expect(MQTTClient.attributesTopic(forDevId: "findmy_a-b", prefix: "findmysyncplus/")
                == "findmysyncplus/findmy_a-b/attributes")
    }
}
