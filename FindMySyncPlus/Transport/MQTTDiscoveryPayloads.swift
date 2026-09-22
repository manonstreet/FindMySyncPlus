import Foundation

// Everything FindMySyncPlus publishes to Home Assistant, and where. All `nonisolated
// static` and pure — no connection, no state, no main actor — so every payload can be
// read and asserted on without the transport around it.
extension MQTTClient {

    /// HA's discovery namespace. Fixed — this prefix is not user-configurable.
    nonisolated static func discoveryTopic(forDevId devId: String) -> String {
        "homeassistant/device_tracker/\(devId)/config"
    }

    // MARK: - App-level topics

    /// One retained availability topic for the whole app, referenced by every discovery
    /// payload. A leaf, not `<prefix>status` — that is a namespace with `status/state`
    /// under it. Renaming it later means clearing the old topic by hand and republishing
    /// every config. No device can collide: `DeviceAlias.entityID` forces the `findmy_` prefix.
    nonisolated static func availabilityTopic(prefix: String) -> String {
        "\(prefix)availability"
    }

    /// HA's own defaults for `payload_available` / `payload_not_available`, so the
    /// discovery payloads need neither key.
    nonisolated static let availabilityOnline = "online"
    nonisolated static let availabilityOffline = "offline"

    /// The one topic this app listens on. The topic is the verb; the payload is ignored.
    /// `refresh_sync`, because what it starts is a full sync run with the Find My relaunch
    /// forced on. Derived from `mqttTopicPrefix` like every other topic.
    nonisolated static func refreshSyncTopic(prefix: String) -> String {
        "\(prefix)refresh_sync"
    }

    nonisolated static let refreshButtonId = "findmysyncplus_refresh_sync"

    nonisolated static func refreshButtonTopic() -> String {
        "homeassistant/button/\(refreshButtonId)/config"
    }

    /// A discovered button, so pressing it in Home Assistant is the whole setup.
    ///
    /// `retain: false` is load-bearing: a retained press would be replayed on every
    /// reconnect and relaunch Find My each time. A singleton like the status entity — it
    /// belongs to the app, not a tracked object, so retired-alias cleanup must never sweep it.
    nonisolated static func refreshButtonPayload(topicPrefix: String) -> [String: Any] {
        [
            "name": "Refresh and sync",
            "unique_id": refreshButtonId,
            "default_entity_id": "button.\(refreshButtonId)",
            "command_topic": refreshSyncTopic(prefix: topicPrefix),
            "retain": false,
            "availability_topic": availabilityTopic(prefix: topicPrefix),
            "device": [
                "identifiers": ["findmysyncplus"],
                "name": "FindMySync+",
                "manufacturer": "Apple",
                "model": "Find My"
            ]
        ]
    }

    nonisolated static let connectedSensorId = "findmysyncplus_connected"

    nonisolated static func connectedDiscoveryTopic() -> String {
        "homeassistant/binary_sensor/\(connectedSensorId)/config"
    }

    /// Is the app connected, as a state rather than an absence. Reads the availability topic
    /// as its `state_topic`: availability would make entities vanish, costing a tracker its
    /// last position and the status entity its diagnostics when they are most wanted; a state
    /// is an automation trigger and leaves the recorder a chartable on/off history.
    /// `payload_on`/`payload_off` are required (a binary sensor defaults to `ON`/`OFF`), and
    /// it carries no availability of its own — its `off` comes from the retained will.
    nonisolated static func connectedPayload(topicPrefix: String) -> [String: Any] {
        [
            "name": "Connected",
            "unique_id": connectedSensorId,
            "default_entity_id": "binary_sensor.\(connectedSensorId)",
            "state_topic": availabilityTopic(prefix: topicPrefix),
            "payload_on": availabilityOnline,
            "payload_off": availabilityOffline,
            "device_class": "connectivity",
            "device": [
                "identifiers": ["findmysyncplus"],
                "name": "FindMySync+",
                "manufacturer": "Apple",
                "model": "Find My"
            ]
        ]
    }

    nonisolated static func statusStateTopic(prefix: String) -> String {
        "\(prefix)status/state"
    }

    nonisolated static func statusAttributesTopic(prefix: String) -> String {
        "\(prefix)status/attributes"
    }

    nonisolated static let statusDevId = "findmysyncplus_status"

    nonisolated static func statusDiscoveryTopic() -> String {
        "homeassistant/sensor/\(statusDevId)/config"
    }

    /// The sync status entity: last successful sync as the state, the run's counts and the
    /// app's health as attributes — without these, "working as intended" and "broken" look
    /// identical from Home Assistant. A singleton, not a devId, so retired-alias cleanup
    /// never sweeps it.
    nonisolated static func statusPayload(topicPrefix: String) -> [String: Any] {
        [
            "name": "Sync status",
            "unique_id": statusDevId,
            "default_entity_id": "sensor.\(statusDevId)",
            "state_topic": statusStateTopic(prefix: topicPrefix),
            "json_attributes_topic": statusAttributesTopic(prefix: topicPrefix),
            // No availability_topic: this entity exists to say why things are quiet, so it
            // has to stay readable at exactly the moment the app has stopped.
            "device_class": "timestamp",
            "device": [
                "identifiers": ["findmysyncplus"],
                "name": "FindMySync+",
                "manufacturer": "Apple",
                "model": "Find My"
            ]
        ]
    }

    /// The auto-discovery config, pure so it can be asserted on without a broker.
    /// `unique_id` and `default_entity_id` differ on purpose — see the tests.
    nonisolated static func discoveryPayload(devId: String,
                                             displayName: String,
                                             topicPrefix: String) -> [String: Any] {
        [
            "name": displayName,
            "unique_id": devId,
            // Ignored on HA >= 2026.4, still honoured below 2025.10, and documented
            // as unable to break discovery either way.
            "object_id": devId,
            // Replaces object_id and carries the domain prefix; HA slugifies the remainder.
            // Slugged here too, so the id we publish (and log) is the one HA creates.
            "default_entity_id": DeviceAlias.haEntityID(forDevId: devId),
            "json_attributes_topic": "\(topicPrefix)\(devId)/attributes",
            // No availability_topic: a week-old `home` is usually still true, and going
            // unavailable would take the position away from presence automations.
            // Staleness is per entity via `location_timestamp`; liveness is the Connected sensor.
            "source_type": "gps",
            "device": [
                "identifiers": ["findmysyncplus"],
                "name": "FindMySync+",
                "manufacturer": "Apple",
                "model": "Find My"
            ]
        ]
    }

    nonisolated static func batterySensorTopic(forDevId devId: String) -> String {
        "homeassistant/sensor/\(devId)_battery/config"
    }

    /// A companion sensor so battery reaches HA's battery card and low-battery blueprints,
    /// which an attribute cannot. Reads the tracker's attributes topic via `value_template`,
    /// so one discovery message per device and no new publishing path. Domain is `sensor.`.
    nonisolated static func batterySensorPayload(devId: String,
                                                 displayName: String,
                                                 topicPrefix: String) -> [String: Any] {
        [
            "name": "\(displayName) Battery",
            "unique_id": "\(devId)_battery",
            "default_entity_id": "sensor.\(haSlug(devId))_battery",
            "state_topic": attributesTopic(forDevId: devId, prefix: topicPrefix),
            // The one place availability is kept: a battery percentage decays and carries no
            // timestamp, so 87% from last week is wrong rather than old. An honest gap in the
            // statistics graph beats a flat line the recorder treats as real.
            "availability_topic": availabilityTopic(prefix: topicPrefix),
            // Guarded: the attributes payload omits battery whenever Apple supplies none, which
            // is transient. Unguarded, every such publish logs a template warning in HA;
            // rendering empty is HA's "ignore this update", so the last percentage stands.
            "value_template": "{% if value_json.battery is defined %}{{ value_json.battery }}{% endif %}",
            "device_class": "battery",
            // Without this HA keeps no long-term statistics, so a battery graph has nothing
            // behind it. Additive; existing history is untouched.
            "state_class": "measurement",
            "unit_of_measurement": "%",
            "device": [
                "identifiers": ["findmysyncplus"],
                "name": "FindMySync+",
                "manufacturer": "Apple",
                "model": "Find My"
            ]
        ]
    }

    nonisolated static func attributesTopic(forDevId devId: String, prefix: String) -> String {
        "\(prefix)\(devId)/attributes"
    }

    /// Which retired devIds still need their retained topics cleared. Filtered against the
    /// live set because an alias can be renamed away and back (a → b → a), and clearing a
    /// devId in use again would delete a working entity.
    nonisolated static func tombstonesToPublish(retired: [String],
                                                liveDevIds: Set<String>) -> [String] {
        var seen: Set<String> = []
        return retired.filter { id in
            guard !liveDevIds.contains(id) else { return false }
            return seen.insert(id).inserted
        }
    }
}
