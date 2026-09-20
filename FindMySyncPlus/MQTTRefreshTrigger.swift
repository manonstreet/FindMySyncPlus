import Foundation
import CocoaMQTT

// The one thing Home Assistant can ask this app to do, and the button that asks it.
// One entry point from the connect ack and one from the delegate. The members it reaches
// are internal rather than private: `private` is file-scoped, so a same-type extension in
// another file cannot see them.
extension MQTTClient {

    // MARK: - Refresh trigger

    /// Subscribe to the one topic this app listens on, if the user has turned it on. Called
    /// from the connect ack inside the `activeClientToken` guard, and re-established on every
    /// reconnect like discovery.
    func subscribeToRefreshTopic() {
        guard let settings, settings.enableRefreshTrigger, let client else { return }
        let topic = Self.refreshSyncTopic(prefix: settings.mqttTopicPrefix)
        client.subscribe(topic, qos: .qos1)
    }

    /// Apply a change to the trigger setting now, rather than at the next connection —
    /// renaming an alias already applies at the moment of the action, and so does this.
    func applyRefreshTriggerSetting(enabled: Bool, prefix: String) {
        guard connectionState == .connected, let client else {
            logger?.info("MQTT: not connected — sync requests will be set up on the next connection")
            return
        }
        applyRefreshTriggerSetting(client: client, enabled: enabled, prefix: prefix)
    }

    /// The connected half, on whichever connection is handed in.
    func applyRefreshTriggerSetting(client: MQTTPublishing, enabled: Bool, prefix: String) {
        let topic = Self.refreshSyncTopic(prefix: prefix)
        if enabled {
            client.subscribe(to: topic)
        } else {
            client.unsubscribe(from: topic)
            logger?.info("MQTT unsubscribed from \(topic)")
        }

        // Settle the button again against the new value: this is a deliberate second pass
        // in one session, which the per-session latch would otherwise block.
        settledRefreshButton = false
        settleRefreshButton(client: client, enabled: enabled, prefix: prefix)
    }

    /// Decide what an inbound message means. The rule is pure so the retained-message guard
    /// can be asserted on; a delegate callback cannot be reached by a test.
    func handleInbound(topic: String, retained: Bool) {
        guard let settings else { return }
        handleInbound(topic: topic, retained: retained,
                      refreshTopic: Self.refreshSyncTopic(prefix: settings.mqttTopicPrefix))
    }

    /// The decision and what follows from it, with the refresh topic handed in.
    func handleInbound(topic: String, retained: Bool, refreshTopic: String) {
        switch Self.inboundOutcome(topic: topic, retained: retained, refreshTopic: refreshTopic) {
        case .ignoredTopic:
            logger?.debug("MQTT: ignoring a message on \(topic)")
        case .droppedRetained:
            // Never silent: this line is the only thing that could explain the symptom, and a
            // silently ignored trigger is the same class of failure as a silently fired one.
            logger?.warn("MQTT: dropped a retained message on \(topic). A retained press "
                         + "would fire on every reconnect — republish it with retain off.")
        case .refresh:
            logger?.info("MQTT: refresh and sync requested on \(topic)")
            onRefreshRequested?()
        }
    }

    /// Publish the refresh button's discovery config, or clear it, once per session. Both
    /// directions: a button left behind after the setting is off presses into a topic nobody
    /// listens on, which looks broken rather than off.
    func settleRefreshButton(client: MQTTPublishing, enabled: Bool, prefix: String) {
        guard !settledRefreshButton, let settings else { return }
        settledRefreshButton = true

        switch Self.refreshButtonAction(enabled: enabled,
                                        wasPublished: settings.refreshButtonPublished) {
        case .publish:
            publishJSON(client: client,
                        topic: Self.refreshButtonTopic(),
                        payload: Self.refreshButtonPayload(topicPrefix: prefix),
                        retain: true)
            settings.refreshButtonPublished = true
            logger?.info("MQTT discovery published for button.\(Self.refreshButtonId)")
        case .clear:
            send(client, empty: Self.refreshButtonTopic())
            settings.refreshButtonPublished = false
            logger?.info("MQTT: removed button.\(Self.refreshButtonId) — "
                         + "Home Assistant requests are switched off")
        case .none:
            break
        }
    }
}
