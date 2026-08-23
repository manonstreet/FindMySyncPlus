import Foundation

struct DeviceAlias: Equatable, Identifiable, Codable {
    var alias: String                     // canonical, unique, slugged
    var tracked: Bool                     // whether this alias is currently posted
    var knownUUIDs: [String]              // most-recent-first list of UUIDs
    var lastSeenName: String?             // latest Apple device name (informational)
    var id: String { alias }

    /// Home Assistant entity ID for this alias (e.g. "findmy_airpods").
    var entityID: String { Self.entityID(for: alias) }

    /// Home Assistant entity ID from an alias key string.
    static func entityID(for alias: String) -> String { "findmy_\(alias)" }

    /// The full Home Assistant entity ID this alias resolves to, e.g.
    /// "device_tracker.findmy_ohrapfel_case".
    ///
    /// `entityID(for:)` above is the dev_id — the topic key and `unique_id`,
    /// which keeps hyphens. This is what HA actually names the entity, and it is
    /// the single source of truth for both the `default_entity_id` we publish and
    /// the value Device Manager displays and copies. Those must not drift apart:
    /// showing an entity ID the app does not publish would be worse than showing
    /// none at all.
    static func haEntityID(for alias: String) -> String {
        haEntityID(forDevId: entityID(for: alias))
    }

    /// The same resolution from a dev_id, for callers that already have one.
    /// This is the only place the entity ID is formatted.
    static func haEntityID(forDevId devId: String) -> String {
        "device_tracker.\(haSlug(devId))"
    }

    private enum CodingKeys: String, CodingKey { case alias, tracked, knownUUIDs, lastSeenName }

    init(alias: String, tracked: Bool, knownUUIDs: [String], lastSeenName: String?) {
        self.alias = alias
        self.tracked = tracked
        self.knownUUIDs = knownUUIDs
        self.lastSeenName = lastSeenName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alias = try c.decode(String.self, forKey: .alias)
        tracked = try c.decode(Bool.self, forKey: .tracked)
        lastSeenName = try c.decodeIfPresent(String.self, forKey: .lastSeenName)
        // Try array first
        if let arr = try? c.decode([String].self, forKey: .knownUUIDs) {
            knownUUIDs = arr
        } else if let set = try? c.decode(Set<String>.self, forKey: .knownUUIDs) {
            // Fallback for older storage: preserve order by sorting
            knownUUIDs = Array(set).sorted()
        } else {
            knownUUIDs = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(alias, forKey: .alias)
        try c.encode(tracked, forKey: .tracked)
        try c.encode(knownUUIDs, forKey: .knownUUIDs)
        try c.encodeIfPresent(lastSeenName, forKey: .lastSeenName)
    }
}
