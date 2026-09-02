import Foundation

// Everything FindMySyncPlus publishes to Home Assistant, and where.
//
// Split out of MQTTClient so the payloads can be read and asserted on without the
// transport around them. They were a dictionary literal inside `post()`, behind a
// connected-socket guard, which is why HA removing `object_id` went unnoticed here
// for four months (issue #22).
//
// All `nonisolated static` and pure: no connection, no state, no main actor.
extension MQTTClient {

    /// HA's discovery namespace. Fixed — this prefix is not user-configurable.
    nonisolated static func discoveryTopic(forDevId devId: String) -> String {
        "homeassistant/device_tracker/\(devId)/config"
    }

    /// The auto-discovery config. Extracted from `post()` so it can be asserted on
    /// without a broker: HA removed `object_id` in Core 2026.4 and now silently
    /// ignores it, which was invisible here for four months because this payload
    /// was a dictionary literal behind a connected-socket guard.
    ///
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
            // Replaces object_id, and carries the domain prefix — HA partitions it
            // off and slugifies the remainder. We slug it ourselves so the value we
            // publish is the entity ID HA will actually create, which is what makes
            // the resolved ID we log truthful.
            "default_entity_id": DeviceAlias.haEntityID(forDevId: devId),
            "json_attributes_topic": "\(topicPrefix)\(devId)/attributes",
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

    /// A companion sensor so battery reaches HA's battery card and the low-battery
    /// blueprints, which an attribute cannot do — the outstanding commitment on #16.
    ///
    /// It reads the attributes topic the tracker already publishes via
    /// `value_template`, so this adds one discovery message per device and no new
    /// publishing path.
    ///
    /// `default_entity_id`, never `object_id`: the payload audit found HA dropped
    /// `object_id` support for `sensor.mqtt` as well, so the original spec for this
    /// sensor would have shipped the identical bug this release exists to fix. Note
    /// the domain is `sensor.`, not `device_tracker.`.
    nonisolated static func batterySensorPayload(devId: String,
                                                 displayName: String,
                                                 topicPrefix: String) -> [String: Any] {
        [
            "name": "\(displayName) Battery",
            "unique_id": "\(devId)_battery",
            "default_entity_id": "sensor.\(haSlug(devId))_battery",
            "state_topic": attributesTopic(forDevId: devId, prefix: topicPrefix),
            // Guarded because the attributes payload omits `battery` whenever Apple
            // supplies none, which is transient rather than per-device. Unguarded,
            // every such publish makes HA log a template warning. Rendering empty is
            // HA's "ignore this update", so the last known percentage stands instead
            // of being replaced by a fabricated one.
            "value_template": "{% if value_json.battery is defined %}{{ value_json.battery }}{% endif %}",
            "device_class": "battery",
            // Without this HA records the state but keeps no long-term statistics, so
            // a battery-over-time graph has nothing behind it. Additive: statistics
            // start from here and existing history is untouched.
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

    /// Which retired devIds still need their retained topics cleared.
    ///
    /// Filtered against the live set because an alias can be renamed away and
    /// back (a -> b -> a); clearing a devId that is in use again would delete a
    /// working entity. No broker read and no ownership guess is involved — the
    /// app retires these itself at the moment the alias changes, so it knows
    /// exactly which topics are its own.
    nonisolated static func tombstonesToPublish(retired: [String],
                                                liveDevIds: Set<String>) -> [String] {
        var seen: Set<String> = []
        return retired.filter { id in
            guard !liveDevIds.contains(id) else { return false }
            return seen.insert(id).inserted
        }
    }
}
