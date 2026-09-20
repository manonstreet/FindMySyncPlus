import Foundation
import CocoaMQTT

enum MQTTConnectionState: Sendable {
    case disconnected
    case connecting
    case connected
}

@MainActor
final class MQTTClient: NSObject, ObservableObject, TransportClient {
    @Published private(set) var connectionState: MQTTConnectionState = .disconnected

    var client: CocoaMQTT?
    private var reconnectTask: Task<Void, Never>?
    private(set) var reconnectAttempts = 0
    private var publishedDiscoveryIds: Set<String> = []
    /// Separate from `publishedDiscoveryIds` on purpose — see
    /// `publishBatterySensorIfNeeded`.
    private var publishedBatterySensorIds: Set<String> = []

    weak var logger: LogStore?
    weak var settings: SettingsStore?
    private var intentionalDisconnect = false

    /// Identity of the client this object currently owns. CocoaMQTT's delegate
    /// callbacks arrive asynchronously and are then hopped to the main actor, so a
    /// client we have already torn down can report state long after it stopped being
    /// the active connection. Compared as a token because `CocoaMQTT` is not `Sendable`.
    private var activeClientToken: ObjectIdentifier?

    /// The availability topic this connection registered its will against. Held rather than
    /// recomputed so `online`, the will and `offline` all name the same topic even if the user
    /// edits `mqttTopicPrefix` mid-session — otherwise a retained `online` would be stranded.
    private var availabilityTopicInUse: String?

    /// Set once this session has published the app-level singletons — the status entity
    /// and the Connected sensor. The same per-session gate the trackers use.
    private var publishedAppEntities = false

    /// Set once this session has settled the refresh button — published when the trigger
    /// is on, cleared when it is off. Both directions run once, so flipping the setting
    /// cannot leave a button behind that presses into nothing.
    var settledRefreshButton = false

    /// Called when a refresh is asked for over MQTT. Set by `AppModel`, which owns the
    /// decision about whether a run may start; this object only decides that a genuine,
    /// non-retained request arrived on the right topic.
    var onRefreshRequested: (@MainActor () -> Void)?

    /// Last published attributes payload per devId, for suppressing repeats. Cleared on
    /// reconnect beside `publishedDiscoveryIds`: discovery is republished then, and a
    /// surviving suppression map would leave an entity with a fresh config and no state.
    private var lastPublishedAttributes: [String: PublishedState] = [:]

    /// When the in-flight attempt started, so a stalled one is replaced rather than
    /// leaving the client wedged in `.connecting`.
    private var connectingSince: Date?

    /// How long the client is kept alive after saying `offline`, so its queued writes
    /// reach the socket before it is released.
    nonisolated static let goodbyeGraceMilliseconds = 500

    nonisolated static let connectingTimeout: TimeInterval = 15

    /// Sized so the whole retry chain (0.25 + 0.5 + 1 + 2 + 4 + 8 + 16 ≈ 32s) finishes
    /// inside one scheduler interval — the minimum is 60s. The sync run is then the
    /// outer retry loop, and the two never overlap: a pre-flight firing while a retry
    /// is queued would cancel it and restart the schedule, so it could never end.
    nonisolated static let maxReconnectAttempts = 7

    func bind(logger: LogStore, settings: SettingsStore) {
        self.logger = logger
        self.settings = settings
    }

    #if DEBUG
    /// Seeds the retry counter so backoff behavior can be tested without opening a
    /// socket. Mirrors `CacheDecryptor.loadKeyForTesting`.
    func setReconnectAttemptsForTesting(_ value: Int) { reconnectAttempts = value }
    #endif

    // MARK: - Connection lifecycle

    /// - Parameter resetBackoff: `true` for a connection the app asks for (startup,
    ///   pre-flight, the connection test), which starts a fresh retry schedule. `false`
    ///   for a scheduled reconnect, which must keep advancing the existing one.
    func connect(settings: SettingsStore, resetBackoff: Bool = true) {
        // `announce: false` — tearing down to reconnect is not going away, and saying
        // offline here would flap the Connected sensor on every retry.
        disconnect(resetBackoff: resetBackoff, announce: false)
        intentionalDisconnect = false
        guard !settings.mqttHost.isEmpty else {
            logger?.warn("MQTT: host not configured")
            return
        }

        // Generated once and persisted, so the broker sees one identity for this
        // install rather than one per launch.
        let clientId = Self.resolveClientId(stored: settings.mqttClientId)
        if settings.mqttClientId != clientId {
            settings.mqttClientId = clientId
            logger?.info("MQTT: client id assigned for this install")
        }
        let mqtt = CocoaMQTT(
            clientID: clientId,
            host: settings.mqttHost,
            port: UInt16(settings.mqttPort)
        )
        if !settings.mqttUsername.isEmpty {
            mqtt.username = settings.mqttUsername
            if !settings.mqttPassword.isEmpty {
                mqtt.password = settings.mqttPassword
            }
        }
        mqtt.keepAlive = 60
        mqtt.autoReconnect = false
        // The last will, registered per connection: the broker publishes it if this Mac
        // disappears without a clean DISCONNECT. That turns the Connected sensor off and
        // takes the battery sensors unavailable, while trackers keep their last position
        // and the status entity keeps its diagnostics.
        availabilityTopicInUse = Self.availabilityTopic(prefix: settings.mqttTopicPrefix)
        mqtt.willMessage = Self.willMessage(prefix: settings.mqttTopicPrefix)
        if settings.mqttUseTLS {
            mqtt.enableSSL = true
            mqtt.allowUntrustCACertificate = true
        }
        mqtt.delegate = self
        client = mqtt
        activeClientToken = ObjectIdentifier(mqtt)

        connectionState = .connecting
        connectingSince = Date()
        logger?.info("MQTT connecting to \(settings.mqttHost):\(settings.mqttPort)")
        _ = mqtt.connect()
    }

    /// - Parameter announce: whether to say `offline` before closing. Quitting passes
    ///   `false` and relies on the will instead, having nothing it can wait for.
    func disconnect(resetBackoff: Bool = true, announce: Bool = true) {
        // A clean DISCONNECT makes the broker discard the will, so an intentional close has
        // to say `offline` itself or Home Assistant keeps reading Connected. An unexpected
        // drop has no client to publish through and is covered by the will.
        let announcing = announce && connectionState == .connected
        if announcing {
            publishAvailability(Self.availabilityOffline)
        }
        intentionalDisconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        // Only a fresh, externally requested connection restarts the schedule. A retry
        // tears the client down too, and resetting here would pin every attempt at the
        // first delay — an endless fast loop that never backs off or gives up.
        if resetBackoff { reconnectAttempts = 0 }
        if announcing, let dying = client {
            // Hold the client alive until its writes land: both frames are written
            // asynchronously, so dropping the last reference in the same turn can
            // deallocate it before either reaches the socket. Safe only here, where the
            // process stays alive; quitting can wait for nothing and uses the will.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(Self.goodbyeGraceMilliseconds))
                dying.disconnect()
            }
        } else {
            client?.disconnect()
        }
        client = nil
        activeClientToken = nil
        connectionState = .disconnected
        connectingSince = nil
        publishedDiscoveryIds.removeAll()
        publishedBatterySensorIds.removeAll()
        publishedAppEntities = false
        lastPublishedAttributes.removeAll()
    }

    // MARK: - Availability

    /// Publish the discovery configs that belong to the app rather than to any tracker.
    /// At connect, not at the end of a run: a sync can return early half a dozen ways, and
    /// published from the run, a machine whose syncs fail would get a retained `online` with
    /// no Connected sensor reading it. The topic it reads is retained, so it resolves at once.
    private func publishAppEntityDiscovery() {
        guard !publishedAppEntities, let client, let settings else { return }
        let prefix = settings.mqttTopicPrefix

        publishJSON(client: client,
                    topic: Self.statusDiscoveryTopic(),
                    payload: Self.statusPayload(topicPrefix: prefix),
                    retain: true)
        publishJSON(client: client,
                    topic: Self.connectedDiscoveryTopic(),
                    payload: Self.connectedPayload(topicPrefix: prefix),
                    retain: true)
        settleRefreshButton(client: client,
                            enabled: settings.enableRefreshTrigger,
                            prefix: prefix)
        publishedAppEntities = true
        logger?.info("MQTT discovery published for sensor.\(Self.statusDevId) "
                     + "and binary_sensor.\(Self.connectedSensorId)")
    }

    /// Publish the app-level availability state, retained so a subscriber that connects
    /// later learns the current state rather than waiting for the next transition.
    private func publishAvailability(_ state: String) {
        guard let target = availabilityPublisher, let topic = availabilityTopicInUse else {
            // Silence left a user unable to tell "the app never said it" from "the broker
            // never delivered it" — two explanations needing opposite fixes.
            logger?.warn("MQTT: could not publish \(state) — no live connection to announce on")
            return
        }
        target.send(CocoaMQTTMessage(topic: topic, string: state, qos: .qos1, retained: true))
        logger?.info("MQTT: published \(state) to \(topic)")
    }

    /// Where availability goes. Normally the socket; in tests, a recorder — `connect()` and
    /// `disconnect()` hold a concrete `CocoaMQTT` that no test can build.
    private var availabilityPublisher: MQTTPublishing? {
        #if DEBUG
        if let testPublisher { return testPublisher }
        #endif
        return client
    }

    #if DEBUG
    private var testPublisher: MQTTPublishing?

    /// Stand a recorder in for the socket and declare the connection live, so the
    /// lifecycle can be asserted on. Mirrors `setReconnectAttemptsForTesting`.
    func setConnectedForTesting(publisher: MQTTPublishing, prefix: String) {
        testPublisher = publisher
        availabilityTopicInUse = Self.availabilityTopic(prefix: prefix)
        connectionState = .connected
    }
    #endif

    func ensureConnected(settings: SettingsStore) async -> Bool {
        if connectionState == .connected { return true }

        // Don't restart an attempt that is already in flight: `connect()` begins by
        // tearing the current client down, which surfaces as an unexpected disconnect.
        let stalled = connectingSince.map { Date().timeIntervalSince($0) > Self.connectingTimeout } ?? true
        if connectionState != .connecting || stalled {
            connect(settings: settings)
        }
        // Wait up to 5 seconds for connection
        for _ in 0..<50 {
            try? await Task.sleep(for: .milliseconds(100))
            if connectionState == .connected { return true }
        }
        return connectionState == .connected
    }

    // MARK: - Connection test

    func testConnection(settings: SettingsStore) async -> (Bool, String) {
        let wasConnected = connectionState == .connected
        if !wasConnected {
            connect(settings: settings)
        }
        // Wait up to 5 seconds
        for _ in 0..<50 {
            try? await Task.sleep(for: .milliseconds(100))
            if connectionState == .connected {
                if !wasConnected {
                    disconnect()
                }
                return (true, "Connected successfully to \(settings.mqttHost):\(settings.mqttPort)")
            }
        }
        let msg = "Connection failed to \(settings.mqttHost):\(settings.mqttPort)"
        if !wasConnected {
            disconnect()
        }
        return (false, msg)
    }

    // MARK: - Publishing

    func post(_ devices: [DevicePoint],
              aliasByUUID: [String: String],
              settings: SettingsStore,
              logger: LogStore,
              dryRun: Bool = false) async -> PostSummary {

        if dryRun {
            for d in devices {
                let uuid = d.id.normalized()
                if let alias = aliasByUUID[uuid] {
                    let devId = DeviceAlias.entityID(for: alias)
                    logger.info("[DRY] Would publish MQTT for dev_id=\(devId)")
                } else {
                    logger.warn("[DRY] Skipping \(uuid): no alias mapping found")
                }
            }
            return PostSummary(successCount: 0, authRejectedCount: 0, transientCount: 0)
        }

        guard connectionState == .connected, let client else {
            logger.warn("MQTT: not connected, skipping publish")
            return PostSummary(successCount: 0, authRejectedCount: 0,
                               transientCount: devices.count)
        }

        var successCount = 0
        var transientCount = 0
        var identicalCount = 0
        var withinThresholdCount = 0
        let prefix = settings.mqttTopicPrefix
        let iso = ISO8601DateFormatter()
        let cycle = AttributeCycle(prefix: prefix, iso: iso,
                                   skipRepeats: settings.skipRepeatedLocations,
                                   minimumMovementMeters: settings.minimumMovementMeters)

        drainRetiredDevIds(client: client, aliasByUUID: aliasByUUID,
                           settings: settings, logger: logger, prefix: prefix)

        for d in devices {
            let uuid = d.id.normalized()
            guard let alias = aliasByUUID[uuid] else {
                transientCount += 1
                logger.warn("MQTT: no alias for UUID \(uuid)")
                continue
            }

            let devId = DeviceAlias.entityID(for: alias)

            // Publish HA auto-discovery config once per session. No `state_topic` on
            // purpose: HA derives tracker state from latitude/longitude in the attributes
            // topic, and publishing state on every sync caused home → not_home → home
            // flapping that reset zone-duration counters.
            if !publishedDiscoveryIds.contains(devId) {
                let configTopic = Self.discoveryTopic(forDevId: devId)
                let configPayload = Self.discoveryPayload(
                    devId: devId,
                    displayName: d.name.isEmpty ? alias : d.name,
                    topicPrefix: prefix
                )
                publishJSON(client: client, topic: configTopic, payload: configPayload, retain: true)
                publishedDiscoveryIds.insert(devId)
                logger.info("MQTT discovery published for \(devId) as device_tracker.\(haSlug(devId))")
            }

            publishBatterySensorIfNeeded(client: client, device: d, devId: devId,
                                         displayName: d.name.isEmpty ? alias : d.name,
                                         prefix: prefix)

            switch publishAttributes(client: client, device: d, devId: devId,
                                     cycle: cycle, logger: logger) {
            case .published:             successCount += 1
            case .skippedIdentical:      identicalCount += 1
            case .skippedWithinThreshold: withinThresholdCount += 1
            case .failed:                transientCount += 1
            }
        }

        // Never silent, and names both reasons: with skipping on, "working as intended" and
        // "broken" look identical from the outside, and the split — nothing changed, against
        // a move the threshold decided was near enough — is what tells them apart.
        let skipped = identicalCount + withinThresholdCount
        if skipped > 0 {
            var reasons = ["\(identicalCount) identical"]
            if withinThresholdCount > 0 {
                reasons.append(String(format: "%d within %.1f m",
                                      withinThresholdCount, settings.minimumMovementMeters))
            }
            logger.info("MQTT: \(skipped) entit\(skipped == 1 ? "y" : "ies") not republished "
                        + "(\(reasons.joined(separator: ", ")))")
        }

        return PostSummary(successCount: successCount,
                           authRejectedCount: 0,
                           transientCount: transientCount,
                           skippedUnchangedCount: skipped)
    }

    /// Build and publish one device's attributes, skipping a payload that repeats the last.
    /// Sound only because `last_update` carries the fix time — see `buildAttributes`. A
    /// record Apple gives no timestamp for keeps the publish time and so never matches
    /// itself: it publishes, loudly, rather than going quiet on a record we cannot reason about.
    private func publishAttributes(client: MQTTPublishing,
                                   device: DevicePoint,
                                   devId: String,
                                   cycle: AttributeCycle,
                                   logger: LogStore) -> AttributePublishOutcome {
        let (prefix, iso, skipRepeats) = (cycle.prefix, cycle.iso, cycle.skipRepeats)
        let attrs = buildAttributes(for: device, iso: iso)
        guard let json = Self.jsonString(attrs), let signature = Self.signature(of: attrs) else {
            logger.warn("[\(devId)] MQTT: attributes could not be serialized; not published")
            return .failed
        }

        let state = PublishedState(signature: signature,
                                   latitude: device.latitude,
                                   longitude: device.longitude)
        switch Self.suppressionDecision(enabled: skipRepeats,
                                        previous: lastPublishedAttributes[devId],
                                        current: state,
                                        thresholdMeters: cycle.minimumMovementMeters) {
        case .identical:
            logger.debug("[\(devId)] unchanged since the last publish — skipped")
            return .skippedIdentical
        case .withinThreshold(let moved):
            logger.debug(String(format: "[%@] moved %.2f m, within %.1f m — skipped",
                                devId, moved, cycle.minimumMovementMeters))
            return .skippedWithinThreshold
        case .publish:
            break
        }

        client.send(CocoaMQTTMessage(topic: Self.attributesTopic(forDevId: devId, prefix: prefix),
                                     string: json, qos: .qos1, retained: true))
        lastPublishedAttributes[devId] = state
        logger.info("[\(devId)] MQTT published")
        return .published
    }

    // MARK: - Status entity

    /// Publish the sync status entity's state and attributes. Every sync, not hourly: an
    /// hourly heartbeat cannot tell you the app died 50 minutes ago.
    /// - Parameter lastSuccessfulSync: `nil` when this run published nothing, which leaves
    ///   the previous timestamp standing — a failed run is precisely when a user must be able
    ///   to see how long ago the last good one was.
    func publishStatus(_ report: SyncStatusReport,
                       lastSuccessfulSync: Date?,
                       prefix: String,
                       iso: ISO8601DateFormatter) {
        guard connectionState == .connected, let client else {
            logger?.debug("MQTT: not connected; status entity not published this run")
            return
        }

        if let lastSuccessfulSync {
            client.send(CocoaMQTTMessage(topic: Self.statusStateTopic(prefix: prefix),
                                         string: iso.string(from: lastSuccessfulSync),
                                         qos: .qos1, retained: true))
        }
        publishJSON(client: client,
                    topic: Self.statusAttributesTopic(prefix: prefix),
                    payload: report.attributes,
                    retain: true)

        // Debug, not info: the run summary already carries these counts at info, and at 288
        // runs a day a second line saying the same thing is buffer churn. What this adds is
        // confirmation the status topics were written, which only matters when they were not.
        logger?.debug("MQTT: sync status published — \(report.published) published, "
                      + "\(report.skippedUnchanged) skipped")
    }

    // MARK: - Re-registration

    /// Delete an entity's discovery config and immediately recreate it, so Home Assistant
    /// registers it afresh and applies `default_entity_id` — which HA consults only at first
    /// registration, so the registry entry has to go before a correct ID can be assigned.
    ///
    /// Destructive by design: removing the config removes the registry entry, taking any
    /// rename, icon or area the user set with it. Only ever call this from an explicit,
    /// confirmed user action.
    func reRegister(devId: String,
                    displayName: String,
                    settings: SettingsStore,
                    logger: LogStore) async -> Bool {
        guard connectionState == .connected, let client else {
            logger.warn("MQTT: not connected — cannot re-register \(devId)")
            return false
        }

        await performReRegister(client: client,
                                devId: devId,
                                displayName: displayName,
                                topicPrefix: settings.mqttTopicPrefix)

        guard connectionState == .connected else {
            logger.warn("MQTT: connection lost while re-registering \(devId); entity was removed but not recreated")
            return false
        }
        logger.info("MQTT: re-registered \(devId) as \(DeviceAlias.haEntityID(forDevId: devId))")
        return true
    }

    /// The publish sequence itself: clear, wait, republish. Split from the guards so it can
    /// be asserted on with a recording publisher — the ordering is the behavior. `delay` is
    /// a parameter for the same reason; production always uses 0.5s.
    func performReRegister(client: MQTTPublishing,
                           devId: String,
                           displayName: String,
                           topicPrefix: String,
                           delay: TimeInterval = 0.5) async {
        // Configs only. The retained attributes message stays, so HA restores the
        // position the moment it re-subscribes — see `clearDiscoveryConfigs`.
        clearDiscoveryConfigs(client: client, devId: devId)

        // HA has to process the removal before the new config lands. Published back
        // to back on one topic, it treats the pair as an update, the registry entry
        // survives, and the stale entity ID with it — the exact thing this fixes.
        if delay > 0 {
            try? await Task.sleep(for: .seconds(delay))
        }

        publishJSON(client: client,
                    topic: Self.discoveryTopic(forDevId: devId),
                    payload: Self.discoveryPayload(devId: devId,
                                                   displayName: displayName,
                                                   topicPrefix: topicPrefix),
                    retain: true)
        publishedDiscoveryIds.insert(devId)
    }

    // MARK: - Attribute building

    /// - Parameter now: the fallback for a record Apple gave no fix time. A parameter so a
    ///   test can advance it — such a record must keep publishing rather than match itself,
    ///   and a fixed clock is the only way to show that.
    func buildAttributes(for device: DevicePoint,
                         iso: ISO8601DateFormatter,
                         now: Date = Date()) -> [String: Any] {
        var attrs: [String: Any] = [
            "latitude": device.latitude,
            "longitude": device.longitude,
            "gps_accuracy": device.accuracy,
            // The fix time, not the publish time — the publish time made every entity's
            // "last updated" read as fresh and the payload unstable every cycle. Falls back
            // to now when Apple supplied no timestamp, so the field stays present.
            "last_update": iso.string(from: device.richAttributes?.timestamp ?? now)
        ]
        // Four attributes, split by meaning rather than by Apple's key name. A single
        // raw value would be ambiguous: `batteryLevel` is a 0–1 fraction and
        // `batteryStatus` a small ordinal, so 1 could mean 100% or the ordinal "full".
        if let level = device.battery {
            attrs["battery"] = Int((level * 100).rounded())
            attrs["battery_level_raw"] = level
        }
        if let code = device.batteryStatusCode {
            // Deliberately not normalized into a percentage: the same ordinal means
            // different things across manufacturers, on scales that cannot be reconciled.
            // Passing it through lets a user map their own.
            attrs["battery_status_raw"] = code
        }
        // Travels beside the raw ordinal, never instead of it, so a user who disagrees
        // with the threshold can template on the raw directly.
        if let low = device.isBatteryLow {
            attrs["battery_low"] = low
        }
        if let charging = device.chargingState {
            attrs["charging_state"] = charging
        }
        if let rich = device.richAttributes {
            if let alt = rich.altitude { attrs["altitude"] = alt }
            if let speed = rich.speed { attrs["speed"] = speed }
            if let course = rich.course { attrs["course"] = course }
            if let vAcc = rich.verticalAccuracy { attrs["vertical_accuracy"] = vAcc }
            if let ts = rich.timestamp {
                attrs["location_timestamp"] = iso.string(from: ts)
            }
            // Apple's own staleness flag, passed through rather than turned into a rule of
            // ours. Absent stays absent: a fabricated false would claim Apple called it current.
            if let isOld = rich.isOld {
                attrs["is_old"] = isOld
            }
            if rich.motionActivityState != nil {
                attrs["motion_state"] = rich.motionStateDescription.lowercased()
            }
            // Names how the fix was obtained, so a crowdsourced fallback is visible
            // rather than silently substituted for a live position.
            if let type = rich.positionType {
                attrs["position_type"] = type
            }
            if let label = rich.locationLabel {
                attrs["location_label"] = label
            }
            // Apple's own accuracy judgement, passed through like `is_old` rather than
            // folded into a rule of ours. Absent stays absent.
            if let inaccurate = rich.isInaccurate {
                attrs["is_inaccurate"] = inaccurate
            }
            if let role = rich.role {
                attrs["role"] = role
            }
            if let emoji = rich.roleEmoji {
                attrs["role_emoji"] = emoji
            }
            // Home Assistant has no built-in reverse geocoding, so this is the one
            // attribute here a user would otherwise install an integration to get.
            if let address = rich.address {
                attrs["address"] = address
            }
            // A group's coordinate is sometimes its own and sometimes a piece's. Naming
            // the source is what stops it reading as a measurement of the whole pair.
            if let source = rich.positionSource {
                attrs["position_source"] = source
            }
            if let separation = rich.separationStatus {
                attrs["separation_status"] = separation
            }
            if let pieces = rich.pieces {
                attrs["pieces"] = pieces
            }
        }
        return attrs
    }

    // MARK: - Helpers

    /// Clear the retained topics of aliases that were renamed, deleted or untracked, then
    /// drop them from the retired list. Filtered against the devIds being published this
    /// cycle, so an alias renamed away and back is never cleared while in use.
    private func drainRetiredDevIds(client: MQTTPublishing,
                                    aliasByUUID: [String: String],
                                    settings: SettingsStore,
                                    logger: LogStore,
                                    prefix: String) {
        let liveDevIds = Set(aliasByUUID.values.map { DeviceAlias.entityID(for: $0) })
        let tombstones = publishTombstones(client: client,
                                           retired: settings.retiredDevIds,
                                           liveDevIds: liveDevIds,
                                           prefix: prefix)
        for devId in tombstones {
            logger.info("MQTT: cleared retained topics for retired \(devId)")
        }
        if !tombstones.isEmpty {
            let cleared = Set(tombstones)
            settings.retiredDevIds = settings.retiredDevIds.filter { !cleared.contains($0) }
        }
        // A retired dev_id that is live again is a decision, not a no-op — say so
        // rather than leaving it to look like nothing happened.
        let stillLive = settings.retiredDevIds.count
        if stillLive > 0 {
            logger.info("MQTT: \(stillLive) retired dev_id(s) still in use, not cleared")
        }
    }

    /// Clear retired entities now, outside a sync run: waiting a full interval for a renamed
    /// entity to disappear reads as a bug. The caller connects first; with no connection this
    /// returns nothing and leaves the persisted list for the next sync.
    func flushRetirements(retired: [String], liveDevIds: Set<String>, prefix: String) -> [String] {
        guard connectionState == .connected, let client else { return [] }
        return publishTombstones(client: client, retired: retired,
                                 liveDevIds: liveDevIds, prefix: prefix)
    }

    /// Clear the retained topics of every retired dev_id that is not live again, and report
    /// which were cleared. Takes plain values rather than a `SettingsStore`, which a test must
    /// never construct; the caller reads and writes the stored list around this.
    @discardableResult
    func publishTombstones(client: MQTTPublishing,
                           retired: [String],
                           liveDevIds: Set<String>,
                           prefix: String) -> [String] {
        let tombstones = Self.tombstonesToPublish(retired: retired, liveDevIds: liveDevIds)
        for devId in tombstones {
            clearRetainedTopics(client: client, devId: devId, prefix: prefix)
        }
        return tombstones
    }

    /// Clear every retained topic for a dev_id. Order matters: the discovery config goes
    /// first so HA drops the entity, then the attributes topic, so the last latitude and
    /// longitude do not linger under a name the user removed.
    func clearRetainedTopics(client: MQTTPublishing, devId: String, prefix: String) {
        clearDiscoveryConfigs(client: client, devId: devId)
        // Retirement clears the attributes topic as well; re-registration deliberately
        // does not.
        send(client, empty: Self.attributesTopic(forDevId: devId, prefix: prefix))
    }

    /// Clear only the two discovery configs, leaving the attributes topic intact. That is
    /// what re-registration wants: emptying the config makes HA drop the entity and its
    /// registry entry, and the retained attributes message lets it restore the position the
    /// moment it re-subscribes.
    private func clearDiscoveryConfigs(client: MQTTPublishing, devId: String) {
        send(client, empty: Self.discoveryTopic(forDevId: devId))
        send(client, empty: Self.batterySensorTopic(forDevId: devId))
        // Allow the sensor to be republished: it is gated per session, and without
        // this a re-registered device would come back without its battery sensor.
        publishedBatterySensorIds.remove(devId)
    }

    /// A zero-length retained message — HA's signal to drop a discovered entity,
    /// and what removes the retained message from the broker.
    func send(_ client: MQTTPublishing, empty topic: String) {
        client.send(CocoaMQTTMessage(topic: topic, string: "", qos: .qos1, retained: true))
    }

    /// Publish the battery sensor's discovery config, once per session per device. Gated on
    /// its own set: a device's battery can be absent on the first sync and present on a later
    /// one, and a set shared with tracker discovery would mean the sensor never appeared.
    func publishBatterySensorIfNeeded(client: MQTTPublishing,
                                      device: DevicePoint,
                                      devId: String,
                                      displayName: String,
                                      prefix: String) {
        // No reading means no sensor: one published with no value shows as `unknown`
        // in HA and clutters the device card.
        guard device.battery != nil, !publishedBatterySensorIds.contains(devId) else { return }

        publishJSON(client: client,
                    topic: Self.batterySensorTopic(forDevId: devId),
                    payload: Self.batterySensorPayload(devId: devId,
                                                       displayName: displayName,
                                                       topicPrefix: prefix),
                    retain: true)
        publishedBatterySensorIds.insert(devId)
        logger?.info("MQTT battery sensor published for \(devId)")
    }

    func publishJSON(client: MQTTPublishing, topic: String, payload: [String: Any], retain: Bool) {
        guard let json = Self.jsonString(payload) else {
            // Was a silent `return`. A payload that cannot be serialized is an entity
            // that never appears in Home Assistant, with nothing anywhere to say why.
            logger?.warn("MQTT: payload for \(topic) could not be serialized; not published")
            return
        }
        client.send(CocoaMQTTMessage(topic: topic, string: json, qos: .qos1, retained: retain))
    }

    /// Decides whether a sync run should start a connection, or leave it to whatever is
    /// already trying. Reconnection has two drivers — the retry chain and the scheduler's
    /// pre-flight — and only one may own it: `connect()` cancels any pending retry, so an
    /// unguarded pre-flight would reset the backoff every cycle and never reach the limit.
    nonisolated static func shouldStartNewConnection(state: MQTTConnectionState,
                                                     retryPending: Bool,
                                                     connectingSince: Date?,
                                                     now: Date = Date()) -> Bool {
        if state == .connected { return false }
        // A queued retry owns reconnection until its chain is exhausted.
        if retryPending { return false }
        if state == .connecting, let since = connectingSince,
           now.timeIntervalSince(since) <= connectingTimeout {
            return false        // an attempt is genuinely in flight
        }
        return true
    }

    /// Exponential from 250ms: 0.25, 0.5, 1, 2, 4, 8, 16, 32, 60… The faults this recovers
    /// from are short — macOS denies local network access for a few hundred milliseconds
    /// while it grants a newly signed binary — and a 5s first retry turned that into a lost
    /// sync run.
    nonisolated static func backoffDelay(forAttempt attempt: Int) -> TimeInterval {
        min(0.25 * pow(2.0, Double(max(1, attempt) - 1)), 60.0)
    }

    private func scheduleReconnect(settings: SettingsStore) {
        reconnectTask?.cancel()
        reconnectAttempts += 1
        guard reconnectAttempts <= Self.maxReconnectAttempts else {
            logger?.warn("MQTT: max reconnect attempts reached")
            // Hand ownership back: with no retry queued, the next sync run's pre-flight
            // starts a fresh schedule rather than leaving the client dead forever.
            reconnectTask = nil
            return
        }
        // Same schedule as `backoffDelay(forAttempt:)`.
        let delay = min(0.25 * pow(2.0, Double(reconnectAttempts - 1)), 60.0)
        connectionState = .connecting
        logger?.warn(String(format: "MQTT reconnecting (attempt %d, %.2fs)", reconnectAttempts, delay))
        let settingsRef = settings
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.connect(settings: settingsRef, resetBackoff: false)
        }
    }
}

// MARK: - CocoaMQTTDelegate

extension MQTTClient: CocoaMQTTDelegate {
    nonisolated func mqtt(_ mqtt: CocoaMQTT, didConnectAck ack: CocoaMQTTConnAck) {
        let accepted = (ack == .accept)
        let ackDesc = "\(ack)"
        let token = ObjectIdentifier(mqtt)
        Task { @MainActor in
            guard token == self.activeClientToken else { return }
            if accepted {
                self.connectionState = .connected
                self.connectingSince = nil
                self.reconnectAttempts = 0
                self.reconnectTask?.cancel()
                self.publishedDiscoveryIds.removeAll()
                self.publishedBatterySensorIds.removeAll()
                self.publishedAppEntities = false
                self.settledRefreshButton = false
                self.lastPublishedAttributes.removeAll()
                self.logger?.info("MQTT connected (discovery will re-publish)")
                self.publishAvailability(Self.availabilityOnline)
                self.subscribeToRefreshTopic()
                self.publishAppEntityDiscovery()
            } else {
                self.logger?.error("MQTT connection rejected: \(ackDesc)")
                self.connectionState = .disconnected
            }
        }
    }

    nonisolated func mqttDidDisconnect(_ mqtt: CocoaMQTT, withError err: (any Error)?) {
        let token = ObjectIdentifier(mqtt)
        Task { @MainActor in
            // A disconnect from a client we've already replaced is our own teardown
            // arriving late, not a connection failure.
            guard token == self.activeClientToken else { return }
            self.connectionState = .disconnected
            self.connectingSince = nil
            if let err {
                self.logger?.warn("MQTT disconnected: \(err.localizedDescription)")
            }
            if !self.intentionalDisconnect, let settings = self.settings {
                self.scheduleReconnect(settings: settings)
            }
        }
    }

    nonisolated func mqtt(_ mqtt: CocoaMQTT, didPublishMessage message: CocoaMQTTMessage, id: UInt16) {}
    nonisolated func mqtt(_ mqtt: CocoaMQTT, didPublishAck id: UInt16) {}
    nonisolated func mqtt(_ mqtt: CocoaMQTT, didReceiveMessage message: CocoaMQTTMessage, id: UInt16) {
        // Read what is needed on this side: `CocoaMQTTMessage` is not Sendable, and the
        // topic and the retained flag are the whole of what the decision uses.
        let topic = message.topic
        let retained = message.retained
        let token = ObjectIdentifier(mqtt)
        Task { @MainActor in
            guard token == self.activeClientToken else { return }
            self.handleInbound(topic: topic, retained: retained)
        }
    }

    nonisolated func mqtt(_ mqtt: CocoaMQTT, didSubscribeTopics success: NSDictionary, failed: [String]) {
        let subscribed = success.allKeys.compactMap { $0 as? String }.sorted()
        let token = ObjectIdentifier(mqtt)
        Task { @MainActor in
            guard token == self.activeClientToken else { return }
            for topic in subscribed {
                self.logger?.info("MQTT subscribed to \(topic)")
            }
            // A subscription that failed means the button and any automation are dead with
            // nothing to say so.
            for topic in failed {
                self.logger?.warn("MQTT: subscription to \(topic) was refused by the broker")
            }
        }
    }
    nonisolated func mqtt(_ mqtt: CocoaMQTT, didUnsubscribeTopics topics: [String]) {}
    nonisolated func mqttDidPing(_ mqtt: CocoaMQTT) {}
    nonisolated func mqttDidReceivePong(_ mqtt: CocoaMQTT) {}
}
