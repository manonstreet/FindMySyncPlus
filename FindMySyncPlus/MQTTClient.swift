import Foundation
import CocoaMQTT

enum MQTTConnectionState: Sendable {
    case disconnected
    case connecting
    case connected
}

@MainActor
final class MQTTClient: NSObject, ObservableObject {
    @Published private(set) var connectionState: MQTTConnectionState = .disconnected

    private var client: CocoaMQTT?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempts = 0
    private var publishedDiscoveryIds: Set<String> = []

    private weak var logger: LogStore?
    private weak var settings: SettingsStore?
    private var intentionalDisconnect = false

    func bind(logger: LogStore, settings: SettingsStore) {
        self.logger = logger
        self.settings = settings
    }

    // MARK: - Connection lifecycle

    func connect(settings: SettingsStore) {
        disconnect()
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

        connectionState = .connecting
        logger?.info("MQTT connecting to \(settings.mqttHost):\(settings.mqttPort)")
        _ = mqtt.connect()
    }

    func disconnect() {
        intentionalDisconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempts = 0
        client?.disconnect()
        client = nil
        connectionState = .disconnected
        publishedDiscoveryIds.removeAll()
    }

    func ensureConnected(settings: SettingsStore) async -> Bool {
        if connectionState == .connected { return true }
        connect(settings: settings)
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

        for d in devices {
            let uuid = d.id.normalized()
            guard let alias = aliasByUUID[uuid] else {
                transientCount += 1
                logger.warn("MQTT: no alias for UUID \(uuid)")
                continue
            }

            let devId = DeviceAlias.entityID(for: alias)

            // Publish HA auto-discovery config (once per session)
            if !publishedDiscoveryIds.contains(devId) {
                let configTopic = "homeassistant/device_tracker/\(devId)/config"
                let configPayload: [String: Any] = [
                    "name": d.name.isEmpty ? alias : d.name,
                    "unique_id": devId,
                    "object_id": devId,
                    "state_topic": "\(prefix)\(devId)/state",
                    "json_attributes_topic": "\(prefix)\(devId)/attributes",
                    "source_type": "gps"
                ]
                publishJSON(client: client, topic: configTopic, payload: configPayload, retain: true)
                publishedDiscoveryIds.insert(devId)
                logger.info("MQTT discovery published for \(devId)")
            }

            // Publish state
            let stateMsg = CocoaMQTTMessage(
                topic: "\(prefix)\(devId)/state",
                string: "not_home",
                qos: .qos1,
                retained: false
            )
            client.publish(stateMsg)

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

    // MARK: - Attribute building

    private func buildAttributes(for device: DevicePoint, iso: ISO8601DateFormatter) -> [String: Any] {
        var attrs: [String: Any] = [
            "latitude": device.latitude,
            "longitude": device.longitude,
            "gps_accuracy": device.accuracy,
            "last_update": iso.string(from: Date())
        ]
        if let b = device.battery {
            attrs["battery"] = Int((b * 100).rounded())
        }
        if let rich = device.richAttributes {
            if let alt = rich.altitude { attrs["altitude"] = alt }
            if let speed = rich.speed { attrs["speed"] = speed }
            if let course = rich.course { attrs["course"] = course }
            if let vAcc = rich.verticalAccuracy { attrs["vertical_accuracy"] = vAcc }
            if let ts = rich.timestamp {
                attrs["location_timestamp"] = iso.string(from: ts)
            }
            if rich.motionActivityState != nil {
                attrs["motion_state"] = rich.motionStateDescription.lowercased()
            }
            if let label = rich.locationLabel {
                attrs["location_label"] = label
            }
        }
        return attrs
    }

    // MARK: - Helpers

    private func publishJSON(client: CocoaMQTT, topic: String, payload: [String: Any], retain: Bool) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        let msg = CocoaMQTTMessage(topic: topic, string: json, qos: .qos1, retained: retain)
        client.publish(msg)
    }

    private func scheduleReconnect(settings: SettingsStore) {
        reconnectTask?.cancel()
        reconnectAttempts += 1
        guard reconnectAttempts <= 10 else {
            logger?.warn("MQTT: max reconnect attempts reached")
            return
        }
        let delay = min(Double(reconnectAttempts) * 5.0, 60.0)
        connectionState = .connecting
        logger?.warn("MQTT reconnecting (attempt \(reconnectAttempts), \(Int(delay))s)")
        let settingsRef = settings
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.connect(settings: settingsRef)
        }
    }
}

// MARK: - CocoaMQTTDelegate

extension MQTTClient: CocoaMQTTDelegate {
    nonisolated func mqtt(_ mqtt: CocoaMQTT, didConnectAck ack: CocoaMQTTConnAck) {
        let accepted = (ack == .accept)
        let ackDesc = "\(ack)"
        Task { @MainActor in
            if accepted {
                self.connectionState = .connected
                self.reconnectAttempts = 0
                self.reconnectTask?.cancel()
                self.publishedDiscoveryIds.removeAll()
                self.logger?.info("MQTT connected (discovery will re-publish)")
            } else {
                self.logger?.error("MQTT connection rejected: \(ackDesc)")
                self.connectionState = .disconnected
            }
        }
    }

    nonisolated func mqttDidDisconnect(_ mqtt: CocoaMQTT, withError err: (any Error)?) {
        Task { @MainActor in
            self.connectionState = .disconnected
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
