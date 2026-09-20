import Testing
import Foundation
@testable import FindMySyncPlus

/// The refresh trigger is the first inbound control path, and "the toggle did nothing until
/// reconnect" lived here and was found by hand. The connection is handed in, so what the
/// client subscribes to and when the callback fires are ordinary assertions.
@Suite("MQTT refresh trigger")
@MainActor
struct MQTTRefreshTriggerTests {

    private static let prefix = "findmysyncplus/"
    private static let topic = "findmysyncplus/refresh_sync"

    /// A closure cannot count into a struct's stored property; a box can.
    private final class Counter {
        var fired = 0
    }

    private func client(counting counter: Counter) -> MQTTClient {
        let client = MQTTClient()
        client.onRefreshRequested = { counter.fired += 1 }
        return client
    }

    // MARK: - Inbound

    @Test("a live press on the refresh topic runs the sync")
    func livePressFires() {
        let counter = Counter()
        client(counting: counter).handleInbound(topic: Self.topic, retained: false,
                                                refreshTopic: Self.topic)
        #expect(counter.fired == 1)
    }

    /// A retained press would replay on every reconnect, relaunching Find My indefinitely
    /// with nothing on screen to explain it.
    @Test("a retained press is dropped")
    func retainedPressDropped() {
        let counter = Counter()
        client(counting: counter).handleInbound(topic: Self.topic, retained: true,
                                                refreshTopic: Self.topic)
        #expect(counter.fired == 0)
    }

    @Test("a message on any other topic does nothing")
    func otherTopicIgnored() {
        let counter = Counter()
        client(counting: counter).handleInbound(topic: "findmysyncplus/findmy_wallet/attributes",
                                                retained: false, refreshTopic: Self.topic)
        #expect(counter.fired == 0)
    }

    // MARK: - Applying the setting while connected

    @Test("switching the trigger on subscribes to the refresh topic now")
    func enableSubscribes() {
        let recorder = RecordingPublisher()
        let client = MQTTClient()
        client.applyRefreshTriggerSetting(client: recorder, enabled: true, prefix: Self.prefix)

        #expect(recorder.subscribed == [Self.topic])
        #expect(recorder.unsubscribed.isEmpty)
    }

    @Test("switching it off unsubscribes now, not at the next connection")
    func disableUnsubscribes() {
        let recorder = RecordingPublisher()
        let client = MQTTClient()
        client.applyRefreshTriggerSetting(client: recorder, enabled: false, prefix: Self.prefix)

        #expect(recorder.unsubscribed == [Self.topic])
        #expect(recorder.subscribed.isEmpty)
    }

    /// The button's discovery config is settled once per session. Changing the setting is a
    /// deliberate second pass, so the latch has to reopen or the button stays as it was.
    @Test("changing the setting reopens the once-per-session button latch")
    func latchReopens() {
        let client = MQTTClient()
        client.settledRefreshButton = true
        client.applyRefreshTriggerSetting(client: RecordingPublisher(), enabled: true,
                                          prefix: Self.prefix)
        #expect(client.settledRefreshButton == false)
    }
}
