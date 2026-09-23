import Testing
import Foundation
@testable import FindMySyncPlus

/// The `update` entity, which puts FindMySync+ in Home Assistant's Settings → Updates beside
/// everything else that reports a version.
///
/// It is read-only: Sparkle owns the install and Home Assistant has no way to drive it. A
/// read-only update entity is a valid one, not a degraded one.
@Suite("Home Assistant update entity")
struct MQTTUpdateEntityTests {

    private let prefix = "findmysyncplus/"

    // MARK: - Discovery

    @Test("It is read-only, which is what leaving out the command topic does")
    func readOnly() {
        let payload = MQTTClient.updatePayload(topicPrefix: prefix)
        #expect(payload["command_topic"] == nil)
        #expect(payload["payload_install"] == nil)
    }

    @Test("The entity id carries the update domain")
    func entityID() {
        let payload = MQTTClient.updatePayload(topicPrefix: prefix)
        #expect(payload["unique_id"] as? String == "findmysyncplus_update")
        #expect(payload["default_entity_id"] as? String == "update.findmysyncplus_update")
    }

    @Test("It joins the existing FindMySync+ device rather than making a second one")
    func joinsTheExistingDevice() {
        let device = MQTTClient.updatePayload(topicPrefix: prefix)["device"] as? [String: Any]
        #expect(device?["identifiers"] as? [String] == ["findmysyncplus"])
        #expect(device?["name"] as? String == "FindMySync+")
    }

    /// `firmware` is the only value `device_class` takes here, and this is an app.
    @Test("device_class stays off")
    func noDeviceClass() {
        #expect(MQTTClient.updatePayload(topicPrefix: prefix)["device_class"] == nil)
    }

    @Test("The topics follow the prefix and the discovery namespace")
    func topics() {
        #expect(MQTTClient.updateStateTopic(prefix: prefix) == "findmysyncplus/update/state")
        #expect(MQTTClient.updateDiscoveryTopic()
                == "homeassistant/update/findmysyncplus_update/config")
        #expect(MQTTClient.updatePayload(topicPrefix: prefix)["state_topic"] as? String
                == "findmysyncplus/update/state")
    }

    // MARK: - The state payload

    @Test("A newer version is published as latest_version")
    func knownLatest() {
        let payload = MQTTClient.updateStatePayload(installed: "2.0b", latest: "2.1b")
        #expect(payload["installed_version"] as? String == "2.0b")
        #expect(payload["latest_version"] as? String == "2.1b")
    }

    /// The key is always present, and `NSNull` when there is no answer.
    ///
    /// Home Assistant reads it as `if "latest_version" in json_payload:`, so an omitted key
    /// leaves whatever the last retained publish set. This message is retained, so a stale
    /// "2.1b available" would outlive a failed check indefinitely. Its own documentation says
    /// an absent key shows no available update; the source says otherwise, and the source is
    /// what runs.
    @Test("An unknown latest version is published as null, never omitted")
    func unknownLatestIsNull() {
        let payload = MQTTClient.updateStatePayload(installed: "2.0b", latest: nil)
        #expect(payload["latest_version"] is NSNull)
        #expect(payload.keys.contains("latest_version"))
        #expect(payload["installed_version"] as? String == "2.0b")
    }

    @Test("The payload is exactly the two versions")
    func payloadKeysAreSettled() {
        let keys = Set(MQTTClient.updateStatePayload(installed: "2.0b", latest: "2.1b").keys)
        #expect(keys == ["installed_version", "latest_version"])
    }

    // MARK: - What Sparkle's state means

    @Test("An available update reports the version the feed named")
    func availableReportsItsVersion() {
        #expect(SparkleUpdater.latestVersion(for: .available(version: "2.1b"),
                                             installed: "2.0b") == "2.1b")
    }

    /// Equal versions are how Home Assistant reads "up to date", so `.current` has to say the
    /// installed one rather than nothing.
    @Test("Up to date reports the installed version")
    func currentReportsInstalled() {
        #expect(SparkleUpdater.latestVersion(for: .current, installed: "2.0b") == "2.0b")
    }

    /// Unknown, rather than "up to date". `UpdateEntity.state` returns `None` when either
    /// version is `None`, so Home Assistant reads unknown — which is the honest answer when
    /// no check has come back. A demo session never starts the updater, so this is also the
    /// state every harness run publishes.
    @Test("A check that has not answered reports nothing")
    func noAnswerReportsNil() {
        #expect(SparkleUpdater.latestVersion(for: .never, installed: "2.0b") == nil)
        #expect(SparkleUpdater.latestVersion(for: .checking, installed: "2.0b") == nil)
        #expect(SparkleUpdater.latestVersion(for: .failed("Could not check for updates"),
                                             installed: "2.0b") == nil)
    }
}
