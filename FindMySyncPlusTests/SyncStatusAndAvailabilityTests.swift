import Testing
import Foundation
import CocoaMQTT
@testable import FindMySyncPlus

/// The 1.5b pieces: a stable client id, availability, the status entity, and skipping
/// a position Find My has already reported.
///
/// Nothing here builds a `SettingsStore`. The test target is hosted by the app bundle
/// and shares the user's real UserDefaults, so constructing one would write over their
/// configuration — which is why each rule below is reachable as a pure function.
@Suite("Sync status, availability and suppression")
@MainActor
struct SyncStatusAndAvailabilityTests {

    private static let prefix = "findmysyncplus/"
    private static let devId = "findmy_wallet"

    // MARK: - Stable client id

    @Test("a stored client id is reused rather than replaced")
    func storedClientIdIsReused() {
        #expect(MQTTClient.resolveClientId(stored: "FindMySyncPlus-abc12345")
                == "FindMySyncPlus-abc12345")
    }

    /// The defect this fixes: a fresh identity every launch, so the broker saw a new
    /// client each time and a broker retaining client state accumulated a dead entry
    /// per launch.
    @Test("an empty stored id yields a new one, and two of them differ")
    func emptyClientIdIsGenerated() {
        let first = MQTTClient.resolveClientId(stored: "")
        let second = MQTTClient.resolveClientId(stored: "")

        #expect(first.hasPrefix("FindMySyncPlus-"))
        #expect(first != second, "each install must get its own id, or two Macs fight over one session")
        #expect(MQTTClient.resolveClientId(stored: first) == first,
                "once stored, it must never change again")
    }

    // MARK: - Availability

    /// `availability` is a leaf and `status/` is a namespace. Upstream PR #50 puts
    /// availability at `<prefix>status`, which works alone and breaks the moment the
    /// status entity arrives — that topic would hold "online" while
    /// `<prefix>status/state` held a timestamp.
    @Test("availability and status occupy separate topics")
    func topicsDoNotCollide() {
        #expect(MQTTClient.availabilityTopic(prefix: Self.prefix) == "findmysyncplus/availability")
        #expect(MQTTClient.statusStateTopic(prefix: Self.prefix) == "findmysyncplus/status/state")
        #expect(MQTTClient.statusAttributesTopic(prefix: Self.prefix)
                == "findmysyncplus/status/attributes")
    }

    /// Battery is the one entity where staleness is wrongness: a percentage decays, and
    /// it carries no timestamp beside it, so an honest gap beats a flat line.
    @Test("only the battery sensor goes unavailable")
    func onlyBatteryCarriesAvailability() {
        let battery = MQTTClient.batterySensorPayload(devId: Self.devId,
                                                      displayName: "Wallet",
                                                      topicPrefix: Self.prefix)
        #expect(battery["availability_topic"] as? String == "findmysyncplus/availability")
    }

    /// A tracker's job is to answer where something is, and a week-old `home` is usually
    /// still true — presence automations depend on it surviving the Mac being off. The
    /// status entity exists to say why things are quiet, so it must never go quiet itself.
    @Test("trackers and the status entity keep their values when the app stops")
    func trackersAndStatusNeverGoUnavailable() {
        let tracker = MQTTClient.discoveryPayload(devId: Self.devId,
                                                  displayName: "Wallet",
                                                  topicPrefix: Self.prefix)
        let status = MQTTClient.statusPayload(topicPrefix: Self.prefix)

        #expect(tracker["availability_topic"] == nil)
        #expect(status["availability_topic"] == nil)
    }

    /// Liveness as a state rather than an absence. It reads the same retained topic the
    /// will writes, so it needs no publishing path of its own — and unlike availability it
    /// leaves the recorder a chartable history of disconnects and reconnects.
    @Test("the Connected sensor reads the availability topic as its state")
    func connectedSensorShape() {
        let payload = MQTTClient.connectedPayload(topicPrefix: Self.prefix)

        #expect(MQTTClient.connectedDiscoveryTopic()
                == "homeassistant/binary_sensor/findmysyncplus_connected/config")
        #expect(payload["state_topic"] as? String == "findmysyncplus/availability")
        #expect(payload["device_class"] as? String == "connectivity")
        // Required: a binary sensor defaults to ON/OFF, which this topic never carries.
        #expect(payload["payload_on"] as? String == "online")
        #expect(payload["payload_off"] as? String == "offline")
        // It has to stay readable to do its job.
        #expect(payload["availability_topic"] == nil)
        #expect(payload["object_id"] == nil)
    }

    @Test("the availability payloads are HA's own defaults, so no extra keys are needed")
    func availabilityPayloadsMatchHomeAssistantDefaults() {
        #expect(MQTTClient.availabilityOnline == "online")
        #expect(MQTTClient.availabilityOffline == "offline")

        let tracker = MQTTClient.discoveryPayload(devId: Self.devId,
                                                  displayName: "Wallet",
                                                  topicPrefix: Self.prefix)
        #expect(tracker["payload_available"] == nil)
        #expect(tracker["payload_not_available"] == nil)
    }

    // MARK: - The connection lifecycle
    //
    // These exist because the bug they guard shipped: the scheduler was stopped, the app's
    // own status light read disconnected, and Home Assistant went on reading Connected —
    // because a clean DISCONNECT makes the broker discard the will, so the retained
    // `online` stood. Nothing could ask the question before, since `disconnect()` holds a
    // concrete `CocoaMQTT`.

    /// Every intentional close routes through `disconnect()`: the scheduler stopping, the
    /// idle release after a user action, a connection test tearing itself down, quitting.
    @Test("disconnecting says offline, rather than leaving a retained online behind")
    func disconnectAnnouncesOffline() throws {
        let recorder = RecordingPublisher()
        let client = MQTTClient()
        client.setConnectedForTesting(publisher: recorder, prefix: Self.prefix)

        client.disconnect()

        #expect(recorder.topics == ["findmysyncplus/availability"])
        let message = try #require(recorder.messages.first)
        #expect(message.string == "offline")
        // Unretained, the broker tells no future subscriber anything.
        #expect(message.retained, "an unretained offline leaves the last retained online standing")
    }

    /// The other half, and the only guard there is for it: quitting sends no clean
    /// DISCONNECT, so the broker fires this. The demo broker implements no wills, so
    /// nothing downstream can check it — an explicit publish at quit was tried and the
    /// frame never reached the wire, because the socket closed in the same turn.
    @Test("the will says offline, retained, on the availability topic")
    func willAnnouncesOffline() {
        let will = MQTTClient.willMessage(prefix: Self.prefix)

        #expect(will.topic == "findmysyncplus/availability")
        #expect(will.string == "offline")
        #expect(will.retained, "an unretained will tells no future subscriber anything")
    }

    /// An unexpected drop leaves no client to publish through, and the broker's will
    /// covers it. Announcing from a connection that was never up would be a lie.
    @Test("disconnecting when nothing is connected publishes nothing")
    func disconnectWhileIdleIsSilent() {
        let recorder = RecordingPublisher()
        let client = MQTTClient()

        client.disconnect()

        #expect(recorder.messages.isEmpty)
    }

    // MARK: - Skipping repeated locations

    private static func state(_ lat: Double, _ lon: Double,
                              signature: String = "{}") -> MQTTClient.PublishedState {
        MQTTClient.PublishedState(signature: signature, latitude: lat, longitude: lon)
    }

    /// Apple Park, matching the fixtures.
    private static let baseLat = 37.3349
    private static let baseLon = -122.0089

    /// Meters north of the base point, using the same constant the app does.
    private static func north(_ meters: Double) -> MQTTClient.PublishedState {
        state(baseLat + meters / 111_320.0, baseLon)
    }

    @Test("nothing is skipped while the setting is off")
    func skippingIsOptIn() {
        #expect(MQTTClient.suppressionDecision(enabled: false,
                                               previous: Self.north(0),
                                               current: Self.north(0),
                                               thresholdMeters: 5) == .publish)
    }

    /// The primary use, and why 0 is the strictest setting rather than an escape hatch:
    /// a stale tracker Apple never rewrites must stop republishing.
    @Test("identical coordinates are skipped at a threshold of zero")
    func identicalSuppressesAtZero() {
        #expect(MQTTClient.suppressionDecision(enabled: true,
                                               previous: Self.north(0),
                                               current: Self.north(0),
                                               thresholdMeters: 0) == .identical)
    }

    /// The off-by-one that would make the feature look enabled and do nothing: two
    /// identical positions are 0 m apart, so `<` would never suppress at a threshold of 0.
    @Test("a threshold of zero still publishes anything that moved at all")
    func zeroPublishesAnyMovement() {
        #expect(MQTTClient.suppressionDecision(enabled: true,
                                               previous: Self.north(0),
                                               current: Self.north(0.01),
                                               thresholdMeters: 0) == .publish)
    }

    /// The row reads "Skip repeated locations", and a repeated location is the same place
    /// again — so a fresh observation of an unchanged position is a repeat, whatever its
    /// timestamp says. One rule at every threshold; the dial only sets how much movement
    /// counts.
    @Test("a fresher timestamp at unchanged coordinates is still a repeat")
    func aNewTimestampAloneIsARepeat() {
        let before = Self.state(Self.baseLat, Self.baseLon, signature: "{}")
        let after = Self.state(Self.baseLat, Self.baseLon, signature: "{}")

        #expect(MQTTClient.suppressionDecision(enabled: true, previous: before,
                                               current: after,
                                               thresholdMeters: 0) == .identical)
    }

    /// Measured on a live account, three stationary runs: an iPhone's recomputed fix moved
    /// 0.01 mm while reporting 3 m accuracy.
    @Test("recompute noise publishes at zero and suppresses at a tenth of a meter")
    func recomputeNoiseSuppresses() {
        let noise = 0.00001
        #expect(MQTTClient.suppressionDecision(enabled: true, previous: Self.north(0),
                                               current: Self.north(noise),
                                               thresholdMeters: 0) == .publish)
        #expect(MQTTClient.suppressionDecision(enabled: true, previous: Self.north(0),
                                               current: Self.north(noise),
                                               thresholdMeters: 0.1) != .publish)
    }

    /// The same measurement, one device over: a stationary Mac wandered 11 cm. This is why
    /// the first threshold proposed — 1 cm — was wrong by two orders of magnitude.
    @Test("an 11 cm wobble publishes at a tenth of a meter and suppresses at half")
    func stationaryWobbleNeedsHalfAMeter() {
        #expect(MQTTClient.suppressionDecision(enabled: true, previous: Self.north(0),
                                               current: Self.north(0.11),
                                               thresholdMeters: 0.1) == .publish)

        let decision = MQTTClient.suppressionDecision(enabled: true, previous: Self.north(0),
                                                      current: Self.north(0.11),
                                                      thresholdMeters: 0.5)
        if case .withinThreshold(let moved) = decision {
            #expect(abs(moved - 0.11) < 0.001)
        } else {
            Issue.record("an 11 cm move must suppress at a 0.5 m threshold")
        }
    }

    /// A real attribute change publishes however wide the threshold — the position is the
    /// only thing allowed to be approximately equal.
    @Test("a battery change publishes even when the device has not moved")
    func attributeChangeAlwaysPublishes() {
        #expect(MQTTClient.suppressionDecision(
            enabled: true,
            previous: Self.state(Self.baseLat, Self.baseLon, signature: #"{"battery":87}"#),
            current: Self.state(Self.baseLat, Self.baseLon, signature: #"{"battery":86}"#),
            thresholdMeters: 50) == .publish)
    }

    /// The first run after a launch or a reconnect sends everything: retained discovery is
    /// republished then, and a config with no state behind it is an empty entity.
    @Test("with no previous state, everything publishes")
    func firstRunAlwaysPublishes() {
        #expect(MQTTClient.suppressionDecision(enabled: true, previous: nil,
                                               current: Self.north(0),
                                               thresholdMeters: 5) == .publish)
    }

    /// Timestamps move whenever Apple rewrites a record, so leaving them in the exact
    /// comparison would publish every recomputed fix whatever the threshold — the feature
    /// would do nothing for the devices it exists to quiet.
    @Test("the signature ignores position and time, and keeps everything else")
    func signatureExcludesOnlyVolatileKeys() throws {
        let attrs: [String: Any] = [
            "latitude": 1.0, "longitude": 2.0, "gps_accuracy": 3.0,
            "last_update": "then", "location_timestamp": "then",
            "battery": 87, "separation_status": "together"
        ]
        let signature = try #require(MQTTClient.signature(of: attrs))

        #expect(signature.contains("battery"))
        #expect(signature.contains("separation_status"))
        for volatile in ["latitude", "longitude", "gps_accuracy",
                         "last_update", "location_timestamp"] {
            #expect(!signature.contains(volatile), "\(volatile) must not decide suppression")
        }
    }

    /// Key order must not decide whether an entity goes quiet.
    @Test("equal payloads serialize byte-identically whatever the insertion order")
    func serializationIsOrderStable() throws {
        let first = try #require(MQTTClient.jsonString(["b": 2, "a": 1]))
        let second = try #require(MQTTClient.jsonString(["a": 1, "b": 2]))
        #expect(first == second)
    }

    // MARK: - The refresh trigger (#25)

    @Test("the topic derives from the prefix, with nothing new to configure")
    func refreshTopicDerivesFromPrefix() {
        #expect(MQTTClient.refreshSyncTopic(prefix: Self.prefix) == "findmysyncplus/refresh_sync")
        #expect(MQTTClient.refreshSyncTopic(prefix: "house/fms/") == "house/fms/refresh_sync")
    }

    /// The topic is the verb and the payload is ignored, so the only questions are which
    /// topic it arrived on and whether the broker replayed it.
    @Test("a message on any other topic is ignored")
    func otherTopicsAreIgnored() {
        #expect(MQTTClient.inboundOutcome(topic: "findmysyncplus/findmy_wallet/attributes",
                                          retained: false,
                                          refreshTopic: "findmysyncplus/refresh_sync")
                == .ignoredTopic)
    }

    @Test("a live press on the refresh topic triggers a run")
    func livePressTriggers() {
        #expect(MQTTClient.inboundOutcome(topic: "findmysyncplus/refresh_sync",
                                          retained: false,
                                          refreshTopic: "findmysyncplus/refresh_sync")
                == .refresh)
    }

    /// The trap this closes: a broker replays a retained message to every new subscriber
    /// and we resubscribe on every reconnect, so one retained press becomes a Find My
    /// relaunch on every reconnect forever — presenting as random launches with the cause
    /// sitting on the broker rather than in our state.
    @Test("a retained press is dropped rather than fired on every reconnect")
    func retainedPressIsDropped() {
        #expect(MQTTClient.inboundOutcome(topic: "findmysyncplus/refresh_sync",
                                          retained: true,
                                          refreshTopic: "findmysyncplus/refresh_sync")
                == .droppedRetained)
    }

    /// `retain: false` on our own button is what keeps it out of that trap.
    @Test("the discovered button pins retain off and is a singleton")
    func refreshButtonShape() {
        let payload = MQTTClient.refreshButtonPayload(topicPrefix: Self.prefix)

        #expect(MQTTClient.refreshButtonTopic()
                == "homeassistant/button/findmysyncplus_refresh_sync/config")
        #expect(payload["retain"] as? Bool == false)
        #expect(payload["command_topic"] as? String == "findmysyncplus/refresh_sync")
        #expect(payload["unique_id"] as? String == "findmysyncplus_refresh_sync")
        #expect(payload["default_entity_id"] as? String == "button.findmysyncplus_refresh_sync")
        #expect(payload["object_id"] == nil)
    }

    /// Retained discovery outlives the app, so switching the trigger off has to clear a
    /// button published in an earlier session — but a user who never switched it on must
    /// not pay an extra retained publish every session for a tombstone they do not need.
    @Test("the button is cleared only if it was ever published")
    func buttonIsClearedOnlyWhenItExists() {
        #expect(MQTTClient.refreshButtonAction(enabled: true, wasPublished: false) == .publish)
        #expect(MQTTClient.refreshButtonAction(enabled: true, wasPublished: true) == .publish)
        #expect(MQTTClient.refreshButtonAction(enabled: false, wasPublished: true) == .clear)
        #expect(MQTTClient.refreshButtonAction(enabled: false, wasPublished: false) == .none)
    }

    private static let epoch = Date(timeIntervalSince1970: 1_756_000_000)

    @Test("a first request runs")
    func firstTriggerRuns() {
        #expect(AppModel.triggerOutcome(isPerformingRun: false, lastTriggeredAt: nil,
                                        now: Self.epoch) == .run)
    }

    /// Drop, do not queue: a refresh already in flight means the fresh data is arriving
    /// anyway, so a queued second run would relaunch Find My for data it already has.
    @Test("a request during a run is dropped as busy")
    func busyIsDropped() {
        #expect(AppModel.triggerOutcome(isPerformingRun: true, lastTriggeredAt: nil,
                                        now: Self.epoch) == .droppedBusy)
    }

    /// An automation loop must not be able to hammer Find My's kill/launch cycle.
    @Test("a second request inside the floor is dropped, and one past it runs")
    func debounceFloorHolds() {
        #expect(AppModel.triggerOutcome(isPerformingRun: false,
                                        lastTriggeredAt: Self.epoch,
                                        now: Self.epoch.addingTimeInterval(59)) == .droppedTooSoon)
        #expect(AppModel.triggerOutcome(isPerformingRun: false,
                                        lastTriggeredAt: Self.epoch,
                                        now: Self.epoch.addingTimeInterval(61)) == .run)
    }

    /// Busy and too-soon are different failures and must never share a line — a silent or
    /// ambiguous drop relocates a fault rather than removing it.
    @Test("busy wins over the floor, so the reason reported is the real one")
    func busyTakesPrecedence() {
        #expect(AppModel.triggerOutcome(isPerformingRun: true,
                                        lastTriggeredAt: Self.epoch,
                                        now: Self.epoch.addingTimeInterval(1)) == .droppedBusy)
    }

    // MARK: - last_update carries the fix time

    private static func point(timestamp: Date?) -> DevicePoint {
        DevicePoint(id: "AAAA", name: "Wallet", latitude: 51.5, longitude: -0.12,
                    accuracy: 12, battery: nil,
                    richAttributes: RichLocationAttributes(
                        verticalAccuracy: nil, altitude: nil, speed: nil, course: nil,
                        timestamp: timestamp, motionActivityState: nil, locationLabel: nil))
    }

    /// `last_update` was `Date()`, so Home Assistant saw an attribute change every
    /// cycle and a 43-hour-old position was presented as having just arrived. It is
    /// also the only reason the payload was unstable, so nothing could be compared
    /// against the previous run.
    @Test("last_update is the fix time, not the publish time")
    func lastUpdateIsTheFixTime() throws {
        let iso = ISO8601DateFormatter()
        let fixedAt = Date(timeIntervalSince1970: 1_756_000_000)
        let attrs = MQTTClient().buildAttributes(for: Self.point(timestamp: fixedAt), iso: iso)

        #expect(attrs["last_update"] as? String == iso.string(from: fixedAt))
        #expect(attrs["last_update"] as? String == attrs["location_timestamp"] as? String)
    }

    /// Two builds of an unchanged record must be byte-identical, or suppression could
    /// never fire.
    @Test("an unchanged record builds the same payload twice")
    func unchangedRecordIsStable() throws {
        let iso = ISO8601DateFormatter()
        let point = Self.point(timestamp: Date(timeIntervalSince1970: 1_756_000_000))
        let client = MQTTClient()

        let first = try #require(MQTTClient.jsonString(client.buildAttributes(for: point, iso: iso)))
        let second = try #require(MQTTClient.jsonString(client.buildAttributes(for: point, iso: iso)))
        #expect(first == second)
    }

    /// The safe direction: a record Apple gives no timestamp for keeps the publish time
    /// and so never matches itself. It publishes every cycle rather than going quiet on
    /// a record we cannot reason about.
    @Test("a record with no fix time never suppresses itself")
    func recordWithoutTimestampKeepsPublishing() throws {
        let iso = ISO8601DateFormatter()
        let point = Self.point(timestamp: nil)
        let client = MQTTClient()
        let firstRun = Date(timeIntervalSince1970: 1_756_000_000)

        let first = try #require(MQTTClient.jsonString(
            client.buildAttributes(for: point, iso: iso, now: firstRun)))
        #expect(first.contains("last_update"),
                "the field must stay present for anyone templating on it")
        #expect(!first.contains("location_timestamp"),
                "no fix time means no location_timestamp — a fabricated one would claim a reading")

        // A sync interval later the payload differs, because `last_update` fell back to the
        // publish time — but suppression no longer reads it. Time-derived keys are excluded
        // from the signature on purpose, so this record is judged on its position like any
        // other, and an unmoved one is skipped.
        let later = try #require(MQTTClient.jsonString(
            client.buildAttributes(for: point, iso: iso,
                                   now: firstRun.addingTimeInterval(300))))
        #expect(first != later, "last_update still moves, even though it no longer decides")

        let signature = try #require(MQTTClient.signature(
            of: client.buildAttributes(for: point, iso: iso, now: firstRun)))
        let laterSignature = try #require(MQTTClient.signature(
            of: client.buildAttributes(for: point, iso: iso,
                                       now: firstRun.addingTimeInterval(300))))
        #expect(signature == laterSignature)
    }
}
