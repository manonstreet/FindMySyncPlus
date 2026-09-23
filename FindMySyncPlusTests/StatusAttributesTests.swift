import Testing
import Foundation
@testable import FindMySyncPlus

/// The status entity and the attribute payload it publishes.
///
/// Split out of `SyncStatusAndAvailabilityTests` in 2.1b, which had grown past both of
/// SwiftLint's size limits — adding `new_unassigned` to the contract was what tipped it. The
/// subject is coherent on its own: one discovery payload and the attributes people template
/// against, which is exactly why a rename after shipping is a breaking change.
///
/// Nothing here builds a `SettingsStore`. The test target is hosted by the app bundle and
/// shares the user's real UserDefaults, so constructing one would write over their
/// configuration.
@Suite("Status entity and its attributes")
@MainActor
struct StatusAttributesTests {

    private static let prefix = "findmysyncplus/"

    /// A singleton, not a devId — which is why retired-alias cleanup never sweeps it.
    @Test("the status entity is a singleton sensor with a timestamp state")
    func statusPayloadShape() {
        let payload = MQTTClient.statusPayload(topicPrefix: Self.prefix)

        #expect(MQTTClient.statusDiscoveryTopic()
                == "homeassistant/sensor/findmysyncplus_status/config")
        #expect(payload["unique_id"] as? String == "findmysyncplus_status")
        #expect(payload["default_entity_id"] as? String == "sensor.findmysyncplus_status")
        #expect(payload["device_class"] as? String == "timestamp")
        #expect(payload["state_topic"] as? String == "findmysyncplus/status/state")
        #expect(payload["json_attributes_topic"] as? String == "findmysyncplus/status/attributes")
        // `object_id` was removed from HA in Core 2026.4 and must not come back here.
        #expect(payload["object_id"] == nil)
    }

    /// Retiring an alias works from an explicit list rather than sweeping the prefix,
    /// so the status entity is safe without an exemption. Asserted because the discovered
    /// button in the refresh-trigger spec *did* need one.
    @Test("retirement never sweeps the app-level singletons")
    func retirementLeavesSingletonsAlone() {
        let singletons = [MQTTClient.statusDevId,
                          MQTTClient.connectedSensorId,
                          MQTTClient.refreshButtonId]
        let tombstones = MQTTClient.tombstonesToPublish(
            retired: ["findmy_old"] + singletons,
            liveDevIds: Set(singletons)
        )
        #expect(tombstones == ["findmy_old"])
    }

    private static func report(skippedUnchanged: Int = 9,
                               sleptDuringRun: Bool = false,
                               findMyLaunched: Bool = true,
                               cacheWritten: Date? = Date(timeIntervalSince1970: 1_756_000_000),
                               lastError: String? = nil) -> SyncStatusReport {
        SyncStatusReport(version: "1.5b", runSeconds: 5.0341,
                         discovered: 13, located: 12, tracked: 11, published: 2,
                         skippedUnchanged: skippedUnchanged, noLocation: 2, unassigned: 1,
                         newUnassigned: 1,
                         sleptDuringRun: sleptDuringRun,
                         findMyLaunched: findMyLaunched, cacheWritten: cacheWritten,
                         keys: "fmip ok, fmf missing, localstorage missing",
                         fullDiskAccess: true, lastError: lastError)
    }

    /// **People template against these**, so a rename after shipping is a breaking
    /// change. The set is asserted whole rather than key by key: a key quietly added or
    /// dropped is exactly what this must catch.
    @Test("the attribute set is exactly the published contract")
    func attributeKeysAreSettled() {
        let keys = Set(Self.report().attributes.keys)

        #expect(keys == [
            "version", "run_seconds", "discovered", "located", "tracked",
            "published", "skipped_unchanged", "no_location", "unassigned",
            "new_unassigned",
            "slept_during_run", "find_my_launched", "cache_written",
            "keys", "full_disk_access", "last_error"
        ])
    }

    /// `new_unassigned` counts the part of `unassigned` nobody has been shown yet, and
    /// `unassigned` keeps its own meaning beside it — somebody may already template against
    /// that one, so 2.1b adds a key rather than narrowing one.
    @Test("new_unassigned is published beside unassigned, not instead of it")
    func newUnassignedSitsBesideUnassigned() {
        let attrs = Self.report().attributes

        #expect(attrs["unassigned"] as? Int == 1)
        #expect(attrs["new_unassigned"] as? Int == 1)
    }

    /// Three separate reasons a device did not publish coexist. A single `skipped`
    /// would not say which, and the other two already have their own keys.
    @Test("the three not-published reasons stay separate")
    func notPublishedReasonsAreDistinct() {
        let attrs = Self.report().attributes

        #expect(attrs["skipped_unchanged"] as? Int == 9)
        #expect(attrs["no_location"] as? Int == 2)
        #expect(attrs["unassigned"] as? Int == 1)
        #expect(attrs["skipped"] == nil, "the ambiguous name must not appear")
    }

    /// `transport` could only ever read "mqtt": the publisher guards on the transport
    /// mode and writes onto the MQTT device block. A constant dressed as data, in a
    /// payload people write templates against.
    @Test("no transport attribute, because it could only say one thing")
    func noConstantTransportAttribute() {
        #expect(Self.report().attributes["transport"] == nil)
    }

    /// Neither half means much alone. The cache advances because we launch Find My, so
    /// "the cache did not move" separates a Find My fault from your own setting only once
    /// `find_my_launched` says whether we asked.
    @Test("the freshness inputs are published raw, not as a verdict")
    func freshnessInputsArePublishedRaw() {
        let written = Date(timeIntervalSince1970: 1_756_000_000)
        let attrs = Self.report(findMyLaunched: true, cacheWritten: written).attributes

        #expect(attrs["find_my_launched"] as? Bool == true)
        #expect(attrs["cache_written"] as? String == ISO8601DateFormatter().string(from: written))
        // No computed staleness: the threshold is the user's to pick.
        #expect(attrs["cache_age"] == nil)
        #expect(attrs["cache_is_stale"] == nil)
    }

    /// A missing cache is normal — `ItemGroups.data` is absent on some machines — and the
    /// key stays present as null so a template reading it needs no guard.
    @Test("an unreadable cache reports null rather than dropping the key")
    func absentCacheReportsNull() {
        #expect(Self.report(cacheWritten: nil).attributes["cache_written"] is NSNull)
    }

    @Test("a run that never launched Find My says so")
    func notLaunchedIsReported() {
        #expect(Self.report(findMyLaunched: false).attributes["find_my_launched"] as? Bool == false)
    }

    /// Passed through like `gps_accuracy`. Rounding was tried and bought nothing —
    /// Foundation serializes an inexact Double at full precision either way.
    @Test("run_seconds is the raw duration")
    func runSecondsIsRaw() {
        #expect(Self.report().attributes["run_seconds"] as? Double == 5.0341)
    }

    /// A run of 961 seconds looks broken on its own and is not. The scheduler no longer
    /// stops on sleep, so this is what is left of the sleep work.
    @Test("a sleep inside the run is reported, not acted on")
    func sleepIsReported() {
        #expect(Self.report(sleptDuringRun: true).attributes["slept_during_run"] as? Bool == true)
        #expect(Self.report().attributes["slept_during_run"] as? Bool == false)
    }

    /// An attribute that vanishes when things are healthy makes every template that
    /// reads it need a guard.
    @Test("last_error is present as null when there is no error")
    func lastErrorIsAlwaysPresent() {
        #expect(Self.report().attributes["last_error"] is NSNull)
        #expect(Self.report(lastError: "Full Disk Access required").attributes["last_error"] as? String
                == "Full Disk Access required")
    }

    /// `present` means stored but never used to decrypt anything. Reporting it as `ok`
    /// would send a user looking anywhere but at the key that is wrong.
    @Test("each key state gets its own word")
    func keyStatesAreDistinguished() {
        #expect(SyncStatusReport.keysDescription(fmip: .valid, fmf: .notPresent,
                                                 localStorage: .notPresent)
                == "fmip ok, fmf missing, localstorage missing")
        #expect(SyncStatusReport.keysDescription(fmip: .present, fmf: .invalid,
                                                 localStorage: .valid)
                == "fmip present, fmf invalid, localstorage ok")
    }
}
