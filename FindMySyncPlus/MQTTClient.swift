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

    private var client: CocoaMQTT?
    private var reconnectTask: Task<Void, Never>?
    private(set) var reconnectAttempts = 0
    private var publishedDiscoveryIds: Set<String> = []
    /// Separate from `publishedDiscoveryIds` on purpose — see
    /// `publishBatterySensorIfNeeded`.
    private var publishedBatterySensorIds: Set<String> = []

    private weak var logger: LogStore?
    private weak var settings: SettingsStore?
    private var intentionalDisconnect = false

    /// Identity of the client this object currently owns. CocoaMQTT's delegate
    /// callbacks arrive asynchronously and are then hopped to the main actor, so a
    /// client we have already torn down can report state long after it stopped being
    /// the active connection. Compared as a token because `CocoaMQTT` is not `Sendable`.
    private var activeClientToken: ObjectIdentifier?

    /// When the in-flight attempt started, so a stalled one is replaced rather than
    /// leaving the client wedged in `.connecting`.
    private var connectingSince: Date?
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
        disconnect(resetBackoff: resetBackoff)
        intentionalDisconnect = false
        guard !settings.mqttHost.isEmpty else {
            logger?.warn("MQTT: host not configured")
            return
        }

        let clientId = "FindMySyncPlus-\(UUID().uuidString.prefix(8))"
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

    func disconnect(resetBackoff: Bool = true) {
        intentionalDisconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        // Only a fresh, externally requested connection restarts the schedule. A retry
        // tears the client down too, and resetting here would pin every attempt at the
        // first delay — an endless fast loop that never backs off or gives up.
        if resetBackoff { reconnectAttempts = 0 }
        client?.disconnect()
        client = nil
        activeClientToken = nil
        connectionState = .disconnected
        connectingSince = nil
        publishedDiscoveryIds.removeAll()
        publishedBatterySensorIds.removeAll()
    }

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
        let prefix = settings.mqttTopicPrefix
        let iso = ISO8601DateFormatter()

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

            // Publish HA auto-discovery config (once per session). The
            // `device` block groups all FindMySync+ entities under a single
            // device card in HA's Devices & Services view. No `state_topic`
            // on purpose — HA derives tracker state from latitude/longitude
            // in json_attributes_topic (device_tracker.mqtt + source_type=gps);
            // publishing state messages on every sync caused home → not_home
            // → home flapping that reset zone-duration counters (commit 4c28f0d).
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

            // Build and publish attributes
            let attrs = buildAttributes(for: d, iso: iso)
            publishJSON(client: client, topic: "\(prefix)\(devId)/attributes", payload: attrs, retain: true)
            successCount += 1
            logger.info("[\(devId)] MQTT published")
        }

        return PostSummary(successCount: successCount,
                           authRejectedCount: 0,
                           transientCount: transientCount)
    }

    // MARK: - Re-registration

    /// Delete an entity's discovery config and immediately recreate it, so Home
    /// Assistant registers it afresh and applies `default_entity_id`.
    ///
    /// This is the only way to fix an entity whose ID was assigned before HA
    /// removed `object_id` in Core 2026.4. `default_entity_id` is consulted only
    /// at first registration — `entity_platform` resolves a known `unique_id` to
    /// its existing entry and keeps that entry's ID — so the registry entry has to
    /// go before a correct ID can be assigned.
    ///
    /// **Destructive by design.** Removing the discovery config removes the
    /// registry entry, taking any rename, icon or area the user set with it. Only
    /// ever call this from an explicit, confirmed user action.
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

    /// The publish sequence itself: clear, wait, republish.
    ///
    /// Split from the guards above so it can be asserted on with a recording
    /// publisher — the ordering *is* the behavior, and nothing else can check it.
    /// `delay` is a parameter for the same reason; production always uses 0.5s.
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

    func buildAttributes(for device: DevicePoint, iso: ISO8601DateFormatter) -> [String: Any] {
        var attrs: [String: Any] = [
            "latitude": device.latitude,
            "longitude": device.longitude,
            "gps_accuracy": device.accuracy,
            "last_update": iso.string(from: Date())
        ]
        // Four attributes, split by meaning rather than by Apple's key name. A single
        // raw value would be ambiguous: `batteryLevel` is a 0–1 fraction and
        // `batteryStatus` a small ordinal, so 1 could mean 100% or the ordinal "full".
        if let level = device.battery {
            attrs["battery"] = Int((level * 100).rounded())
            attrs["battery_level_raw"] = level
        }
        if let code = device.batteryStatusCode {
            // Deliberately not normalized into a percentage. The same ordinal means
            // different things across manufacturers — observed values 0, 1, 2, 4, 5 and
            // 100 from Apple, Sitecom and World Tag hardware, on scales that cannot be
            // reconciled. Passing it through lets a user map their own.
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
            // Apple's own flag for whether the fix is stale, passed through rather
            // than turned into a staleness rule of ours — the threshold is the
            // user's to pick, which is what issue #17 asked for. Absent stays
            // absent: a fabricated false would claim Apple called the fix current.
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

    /// Clear the retained topics of aliases that were renamed, deleted or
    /// untracked, then drop them from the retired list.
    ///
    /// Filtered against the devIds being published this cycle, so an alias renamed
    /// away and back is never cleared while it is in use.
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

    /// Clear retired entities now, outside a sync run.
    ///
    /// Renaming, deleting or untracking an alias is a user action, and waiting up to
    /// a full sync interval for the old entity to disappear from Home Assistant reads
    /// as a bug. The caller is responsible for connecting first; this returns nothing
    /// if there is no connection, leaving the persisted list for the next sync.
    func flushRetirements(retired: [String], liveDevIds: Set<String>, prefix: String) -> [String] {
        guard connectionState == .connected, let client else { return [] }
        return publishTombstones(client: client, retired: retired,
                                 liveDevIds: liveDevIds, prefix: prefix)
    }

    /// Clear the retained topics of every retired dev_id that is not live again,
    /// and report which ones were cleared.
    ///
    /// Takes plain values rather than a `SettingsStore`: the test target is hosted
    /// by the app bundle and shares the user's real UserDefaults, so a test must
    /// never construct one. The caller reads and writes the stored list around this.
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

    /// Clear every retained topic for a dev_id.
    ///
    /// A zero-length retained payload is HA's signal to drop a discovered entity,
    /// and removes the retained message from the broker. Order matters: the
    /// discovery config goes first so HA drops the entity, then the attributes
    /// topic, so the device's last latitude/longitude does not linger behind under
    /// a name the user removed.
    func clearRetainedTopics(client: MQTTPublishing, devId: String, prefix: String) {
        clearDiscoveryConfigs(client: client, devId: devId)
        // Retirement clears the attributes topic as well: the alias is gone, and
        // its last latitude/longitude must not sit on the broker under a name the
        // user deliberately removed. Re-registration deliberately does NOT do this.
        send(client, empty: Self.attributesTopic(forDevId: devId, prefix: prefix))
    }

    /// Clear only the two discovery configs, leaving the attributes topic intact.
    ///
    /// This is what re-registration wants. Emptying the discovery config is what
    /// makes HA drop the entity and its registry entry; the retained attributes
    /// message is independent, and leaving it means HA subscribes on re-creation
    /// and restores the position immediately. Clearing it too — which this used to
    /// do — left the recreated entity with no location until the next sync.
    private func clearDiscoveryConfigs(client: MQTTPublishing, devId: String) {
        send(client, empty: Self.discoveryTopic(forDevId: devId))
        send(client, empty: Self.batterySensorTopic(forDevId: devId))
        // Allow the sensor to be republished: it is gated per session, and without
        // this a re-registered device would come back without its battery sensor.
        publishedBatterySensorIds.remove(devId)
    }

    /// A zero-length retained message — HA's signal to drop a discovered entity,
    /// and what removes the retained message from the broker.
    private func send(_ client: MQTTPublishing, empty topic: String) {
        client.send(CocoaMQTTMessage(topic: topic, string: "", qos: .qos1, retained: true))
    }

    /// Publish the battery sensor's discovery config, once per session per device.
    ///
    /// Gated on its own set rather than `publishedDiscoveryIds`: tracker discovery
    /// fires on the first sync, but a device's battery can be absent then and
    /// present on a later one, and a shared set would mean the sensor never
    /// appeared for it.
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

    private func publishJSON(client: MQTTPublishing, topic: String, payload: [String: Any], retain: Bool) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        client.send(CocoaMQTTMessage(topic: topic, string: json, qos: .qos1, retained: retain))
    }

    /// Exponential from 250ms: 0.25, 0.5, 1, 2, 4, 8, 16, 32, 60…
    ///
    /// The faults this recovers from are short. macOS denies local network access with
    /// EHOSTUNREACH while it establishes a grant for a newly-signed binary — which
    /// happens on first launch after every update — and the window measured ~320ms. A
    /// 5s first retry turned that into a 5s outage plus a discarded sync run, because
    /// the pre-flight gave up at exactly the moment the backoff was due to fire.
    /// Decides whether a sync run should start a connection, or leave it to whatever is
    /// already trying.
    ///
    /// Reconnection has two possible drivers — the retry chain and the scheduler's
    /// pre-flight — and only one may own it at a time. `connect()` tears down the
    /// current client and cancels any pending retry, so a pre-flight that fires while a
    /// retry is queued silently restarts the backoff schedule. Left unguarded, the
    /// schedule resets every sync cycle and never reaches its attempt limit.
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
        // Exponential from 250ms: 0.25, 0.5, 1, 2, 4, 8, 16, 32, 60…
        // The faults this recovers from are short. A measured case: the process got
        // ENETDOWN for ~320ms while the system network path reported satisfied. A raw
        // NWConnection rode it out and was ready 320ms later; CocoaMQTT treated it as
        // fatal, and a 5s first retry turned that into a 5s outage plus a discarded
        // sync run — the pre-flight gave up at the moment the backoff was due to fire.
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
                self.logger?.info("MQTT connected (discovery will re-publish)")
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
    nonisolated func mqtt(_ mqtt: CocoaMQTT, didReceiveMessage message: CocoaMQTTMessage, id: UInt16) {}
    nonisolated func mqtt(_ mqtt: CocoaMQTT, didSubscribeTopics success: NSDictionary, failed: [String]) {}
    nonisolated func mqtt(_ mqtt: CocoaMQTT, didUnsubscribeTopics topics: [String]) {}
    nonisolated func mqttDidPing(_ mqtt: CocoaMQTT) {}
    nonisolated func mqttDidReceivePong(_ mqtt: CocoaMQTT) {}
}
