import Foundation
import CocoaMQTT

// The decisions MQTT publishing makes, separated from the connection that acts on them.
// All `nonisolated static` and pure — no socket, no state, no main actor — so the rules
// that decide whether an entity goes quiet or a Find My relaunch fires are testable.
extension MQTTClient {

    /// The stored client id, or a fresh one when nothing is stored yet. Pure, because a test
    /// must never build a `SettingsStore` (it shares the app's real UserDefaults). A stable
    /// id buys one identity on the broker instead of one per launch; sessions are not
    /// resumed (`cleanSession` stays true) and the will is registered per connection anyway.
    nonisolated static func resolveClientId(stored: String) -> String {
        stored.isEmpty ? "FindMySyncPlus-\(UUID().uuidString.prefix(8))" : stored
    }

    enum InboundOutcome: Equatable {
        case refresh
        case ignoredTopic
        case droppedRetained
    }

    /// A retained message is replayed to every new subscriber, and we resubscribe on every
    /// reconnect — so one `retain: true` press would relaunch Find My on every reconnect,
    /// indefinitely, with nothing on screen to explain it. Dropped, and logged by the caller.
    nonisolated static func inboundOutcome(topic: String,
                                           retained: Bool,
                                           refreshTopic: String) -> InboundOutcome {
        guard topic == refreshTopic else { return .ignoredTopic }
        return retained ? .droppedRetained : .refresh
    }

    enum RefreshButtonAction: Equatable {
        case publish
        case clear
        case none
    }

    /// Clearing is conditional on having published, so a user who never switched the trigger
    /// on never pays a tombstone for it.
    nonisolated static func refreshButtonAction(enabled: Bool,
                                                wasPublished: Bool) -> RefreshButtonAction {
        if enabled { return .publish }
        return wasPublished ? .clear : .none
    }

    /// A payload as the exact string that goes on the wire. `sortedKeys` so equal content is
    /// byte-identical; the repeat check compares these strings.
    nonisolated static func jsonString(_ payload: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    /// The last will: retained `offline` on the availability topic. Quitting deliberately
    /// sends no clean DISCONNECT — a broker discards the will on one, and an `offline`
    /// published in the same turn as the close never reaches the wire — so quitting takes the
    /// same path as a crash. Extracted so the shape can be asserted without a socket.
    nonisolated static func willMessage(prefix: String) -> CocoaMQTTMessage {
        CocoaMQTTMessage(topic: availabilityTopic(prefix: prefix),
                         string: availabilityOffline,
                         qos: .qos1,
                         retained: true)
    }

    /// What happened to one device's attributes this cycle. Three outcomes rather than a
    /// `Bool`: a skip is the feature working, a failure is an entity silently going dark.
    enum AttributePublishOutcome {
        case published
        /// "Nothing changed" and "moved less than you asked me to care about" are different
        /// answers to "why did my entity go quiet"; only the second is a decision the app made.
        case skippedIdentical
        case skippedWithinThreshold
        case failed
    }

    /// The parts of a publish cycle that are the same for every device in it.
    struct AttributeCycle {
        let prefix: String
        let iso: ISO8601DateFormatter
        let skipRepeats: Bool
        let minimumMovementMeters: Double
    }

    // MARK: - Suppressing a position that has not meaningfully moved

    /// What the last publish for one entity looked like.
    ///
    /// The position is held apart from the rest because the two are compared differently:
    /// everything else has to match exactly, while the position only has to be close.
    struct PublishedState {
        let signature: String
        let latitude: Double
        let longitude: Double
    }

    enum SuppressionDecision: Equatable {
        case publish
        /// Same coordinates to the last decimal.
        case identical
        /// Moved, but no further than the threshold. Carries the distance, because a user
        /// debugging silence needs to know how far it decided was near enough.
        case withinThreshold(Double)
    }

    /// Attributes left out of the exact comparison. Position, because it is compared by
    /// distance — Apple recomputes a fix on every refresh, so exact comparison suppressed
    /// almost nothing. Time, because `last_update` and `location_timestamp` move whenever
    /// Apple rewrites a record. A repeated location is the same place again, whatever its
    /// timestamp says; a skipped entity's timestamps stop advancing in Home Assistant, and
    /// app-level freshness lives on the status entity.
    nonisolated static let volatileAttributeKeys: Set<String> = [
        "latitude", "longitude", "gps_accuracy", "altitude", "vertical_accuracy",
        "speed", "course", "last_update", "location_timestamp"
    ]

    /// The payload minus everything that moves on its own, as a comparable string.
    nonisolated static func signature(of attrs: [String: Any]) -> String? {
        jsonString(attrs.filter { !volatileAttributeKeys.contains($0.key) })
    }

    /// Meters between two coordinates. Equirectangular rather than haversine: at a few meters
    /// the two agree far beyond the inputs' precision. Longitude shrinks by cos(latitude).
    nonisolated static func metersBetween(_ fromLat: Double, _ fromLon: Double,
                                          _ toLat: Double, _ toLon: Double) -> Double {
        let metersPerDegreeLatitude = 111_320.0
        let northing = (toLat - fromLat) * metersPerDegreeLatitude
        let meanLatitude = ((fromLat + toLat) / 2) * .pi / 180
        let easting = (toLon - fromLon) * metersPerDegreeLatitude * cos(meanLatitude)
        return (northing * northing + easting * easting).squareRoot()
    }

    /// Whether this entity's update can be held back. The toggle owns on and off; the
    /// threshold only widens — 0 means identical coordinates only, not "publish everything".
    /// `<=` rather than `<`, or a threshold of 0 would never suppress anything. No previous
    /// state always publishes, so the first run after a launch or reconnect sends everything.
    nonisolated static func suppressionDecision(enabled: Bool,
                                                previous: PublishedState?,
                                                current: PublishedState,
                                                thresholdMeters: Double) -> SuppressionDecision {
        guard enabled, let previous else { return .publish }

        // Any real attribute change — battery, charging, separation — publishes however
        // wide the threshold. Only the position is allowed to be approximately equal.
        guard previous.signature == current.signature else { return .publish }

        let moved = metersBetween(previous.latitude, previous.longitude,
                                  current.latitude, current.longitude)
        if moved == 0 { return .identical }
        return moved <= thresholdMeters ? .withinThreshold(moved) : .publish
    }
}
