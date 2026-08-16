import Testing
import Foundation
@testable import FindMySyncPlus

/// Apple stores battery two different ways and reuses one key for both:
///
/// | file           | `batteryLevel`     | `batteryStatus`                          |
/// |----------------|--------------------|------------------------------------------|
/// | `Devices.data` | fraction 0–1       | String charging state (Charging/Unknown) |
/// | `Items.data`   | absent             | Int ordinal battery level                |
///
/// So the same key means a charging state on one and a battery level on the other,
/// and a 0–1 fraction collides with a small ordinal at the value 1. These tests pin
/// the separation.
@Suite("Battery parsing")
struct BatteryParsingTests {

    @Test("reads a genuine level and charging state from a device")
    func genuineDeviceReading() {
        let reading = CacheDecryptor.parseBattery(["batteryLevel": 0.78, "batteryStatus": "NotCharging"])

        #expect(reading.level == 0.78)
        #expect(reading.chargingState == "NotCharging")
        #expect(reading.statusCode == nil, "a device's status is a charging state, not an ordinal")
    }

    /// Devices with no battery still carry `batteryLevel = 0` — a desktop Mac, which
    /// has no battery at all, appears this way. Publishing that as 0% is a permanent
    /// false low-battery alert.
    @Test("treats level 0 with an Unknown status as no reading at all")
    func absentBatteryIsNotZero() {
        let reading = CacheDecryptor.parseBattery(["batteryLevel": 0.0, "batteryStatus": "Unknown"])

        #expect(reading.level == nil, "no data must not be published as 0%")
        #expect(reading.chargingState == "Unknown", "the raw status still passes through")
    }

    /// The pairing is load-bearing: a device genuinely at zero still reports a charging
    /// state, so it must keep publishing 0 rather than being swallowed with the no-data case.
    @Test("keeps a real zero when the device reports a charging state")
    func genuineZeroIsKept() {
        let reading = CacheDecryptor.parseBattery(["batteryLevel": 0.0, "batteryStatus": "NotCharging"])

        #expect(reading.level == 0.0, "genuinely flat is a real reading")
    }

    /// Items carry no `batteryLevel` at all — only an ordinal whose meaning varies by
    /// manufacturer. The old code divided it by 100 on the assumption it was a
    /// percentage, so a tracker reporting 2 was published to Home Assistant as 2%.
    @Test("passes an item's ordinal through untouched, never as a percentage")
    func itemOrdinalIsNotAPercentage() {
        let reading = CacheDecryptor.parseBattery(["batteryStatus": 2])

        #expect(reading.statusCode == 2, "the ordinal is passed through unmodified")
        #expect(reading.level == nil, "an ordinal is not a charge level — 2 is not 2%")
        #expect(reading.chargingState == nil, "an Int status is not a charging state")
    }

    /// Values are not interpreted at all, so an unfamiliar one is carried rather than
    /// dropped or coerced. Observed across two users: 0, 1, 2, 4, 5 and 100 — from
    /// Apple, Sitecom and World Tag hardware, on scales that cannot be reconciled.
    @Test("carries any ordinal, including unfamiliar ones",
          arguments: [0, 1, 2, 3, 4, 5, 100])
    func carriesAnyOrdinal(code: Int) {
        let reading = CacheDecryptor.parseBattery(["batteryStatus": code])

        #expect(reading.statusCode == code)
        #expect(reading.level == nil)
    }

    /// Apple uses one key for two vocabularies. A charging state must never be read as
    /// a battery level, and a named level must never be read as a charging state.
    @Test("separates charging states from named battery levels",
          arguments: [("Charging", nil as Double?, "Charging" as String?),
                      ("NotCharging", nil, "NotCharging"),
                      ("Unknown", nil, "Unknown"),
                      ("full", 1.0, nil),
                      ("low", 0.25, nil),
                      ("verylow", 0.1, nil)])
    func chargingStateVersusNamedLevel(word: String, level: Double?, charging: String?) {
        let reading = CacheDecryptor.parseBattery(["batteryStatus": word])

        #expect(reading.level == level)
        #expect(reading.chargingState == charging)
        #expect(reading.statusCode == nil)
    }

    @Test("reports nothing when the device carries no battery fields")
    func noBatteryFieldsAtAll() {
        let reading = CacheDecryptor.parseBattery(["name": "something"])

        #expect(reading == CacheDecryptor.BatteryReading())
    }
}

// MARK: - Plumbing through parseDeviceArray

@Suite("Battery reaches DevicePoint")
struct BatteryPlumbingTests {

    private func located(_ extra: [String: Any]) -> [String: Any] {
        var d: [String: Any] = [
            "baUUID": "AAAABBBB-CCCC-DDDD-EEEE-FFFF00001111",
            "name": "Test Device",
            "location": ["latitude": 1.0, "longitude": 2.0, "horizontalAccuracy": 5.0]
        ]
        for (k, v) in extra { d[k] = v }
        return d
    }

    @Test("a device's level and charging state reach the point")
    func devicePlumbing() throws {
        let points = CacheDecryptor().parseDeviceArray(
            [located(["batteryLevel": 0.61, "batteryStatus": "Charging"])])

        let p = try #require(points.first)
        #expect(p.battery == 0.61)
        #expect(p.chargingState == "Charging")
        #expect(p.batteryStatusCode == nil)
    }

    @Test("an item's ordinal reaches the point without becoming a level")
    func itemPlumbing() throws {
        let points = CacheDecryptor().parseDeviceArray(
            [located(["batteryStatus": 2])])

        let p = try #require(points.first)
        #expect(p.batteryStatusCode == 2)
        #expect(p.battery == nil, "2 must not arrive as 2%")
    }

    @Test("a device with no battery data carries no level")
    func absentPlumbing() throws {
        let points = CacheDecryptor().parseDeviceArray(
            [located(["batteryLevel": 0.0, "batteryStatus": "Unknown"])])

        let p = try #require(points.first)
        #expect(p.battery == nil)
        #expect(p.chargingState == "Unknown")
    }

    @Test("with() preserves the new battery fields")
    func withPreservesBatteryFields() throws {
        let points = CacheDecryptor().parseDeviceArray(
            [located(["batteryStatus": 4])])
        let p = try #require(points.first)

        let renamed = p.with(name: "Renamed")

        #expect(renamed.batteryStatusCode == 4, "copy must not silently drop battery fields")
        #expect(renamed.name == "Renamed")
    }
}

// MARK: - What reaches Home Assistant

/// Four attributes rather than one, split by *meaning*. A single `battery_raw` would be
/// ambiguous: `batteryLevel` is a 0–1 fraction and `batteryStatus` a small ordinal, so
/// the value 1 could be either 100% or the ordinal "full".
@Suite("MQTT battery attributes")
@MainActor
struct BatteryAttributeTests {

    private func point(battery: Double? = nil,
                       statusCode: Int? = nil,
                       chargingState: String? = nil) -> DevicePoint {
        DevicePoint(id: "uuid", name: "Test", latitude: 1, longitude: 2, accuracy: 3,
                    battery: battery, batteryStatusCode: statusCode, chargingState: chargingState)
    }

    private func attrs(_ p: DevicePoint) -> [String: Any] {
        MQTTClient().buildAttributes(for: p, iso: ISO8601DateFormatter())
    }

    @Test("a real level publishes both a percentage and the underlying fraction")
    func levelPublishesBoth() {
        let a = attrs(point(battery: 0.78, chargingState: "NotCharging"))

        #expect(a["battery"] as? Int == 78)
        #expect(a["battery_level_raw"] as? Double == 0.78)
        #expect(a["charging_state"] as? String == "NotCharging")
        #expect(a["battery_status_raw"] == nil, "a device has no ordinal")
    }

    @Test("an item's ordinal publishes raw, with no percentage invented for it")
    func ordinalPublishesRawOnly() {
        let a = attrs(point(statusCode: 2))

        #expect(a["battery_status_raw"] as? Int == 2)
        #expect(a["battery"] == nil, "we cannot map a third-party ordinal to a percentage")
        #expect(a["battery_level_raw"] == nil)
        #expect(a["charging_state"] == nil)
    }

    @Test("a device with no battery data publishes no battery attributes at all")
    func absentPublishesNothing() {
        let a = attrs(point(chargingState: "Unknown"))

        #expect(a["battery"] == nil, "absent must not be published as 0%")
        #expect(a["battery_level_raw"] == nil)
        #expect(a["battery_status_raw"] == nil)
        #expect(a["charging_state"] as? String == "Unknown")
    }
}

// MARK: - Unmapped Apple enums must stay visible

/// Same failure shape as the battery ordinal: a value Apple added that we don't know
/// about must not collapse into a legitimate-looking one. `decodeLocationLabel` is the
/// model — unrecognised input passes through visibly rather than being absorbed.
@Suite("Motion state")
struct MotionStateTests {

    private func attrs(motion: Int?) -> RichLocationAttributes {
        RichLocationAttributes(verticalAccuracy: nil, altitude: nil, speed: nil,
                               course: nil, timestamp: nil,
                               motionActivityState: motion, locationLabel: nil)
    }

    @Test("maps the states Apple is known to use",
          arguments: [(0, "Unknown"), (1, "Stationary"), (2, "Walking"),
                      (3, "Running"), (4, "Automotive"), (5, "Cycling")])
    func mapsKnownStates(raw: Int, expected: String) {
        #expect(attrs(motion: raw).motionStateDescription == expected)
    }

    /// A genuine 0 means Apple told us the state is unknown. An unmapped 7 means *we*
    /// don't know. Reporting both as "Unknown" makes a new Apple activity type
    /// indistinguishable from a real reading, and silently undiagnosable.
    @Test("keeps an unmapped value visible instead of reporting it as Unknown")
    func unmappedStaysVisible() {
        let description = attrs(motion: 7).motionStateDescription

        #expect(description != "Unknown", "an unmapped value must not look like a real one")
        #expect(description.contains("7"), "the raw value must survive so it can be reported")
    }

    @Test("treats an absent state as unknown")
    func absentIsUnknown() {
        #expect(attrs(motion: nil).motionStateDescription == "Unknown")
    }
}

// MARK: - Reconnect backoff

/// `connect()` begins by tearing down the current client, and the teardown used to
/// reset the attempt counter. Since every scheduled reconnect goes through `connect()`,
/// the counter never advanced: every retry was attempt 1, at the shortest delay,
/// forever — the attempt cap was unreachable and the backoff never backed off.
@Suite("MQTT reconnect backoff")
@MainActor
struct ReconnectBackoffTests {

    private func client() -> (MQTTClient, SettingsStore) {
        let c = MQTTClient()
        let s = SettingsStore()
        s.mqttHost = ""     // connect() returns early, so no socket is opened
        return (c, s)
    }

    @Test("a reconnect attempt does not reset the counter")
    func reconnectPreservesAttempts() {
        let (c, s) = client()
        c.setReconnectAttemptsForTesting(5)

        c.connect(settings: s, resetBackoff: false)

        #expect(c.reconnectAttempts == 5, "a retry must not restart the backoff schedule")
    }

    @Test("an externally requested connection does reset the counter")
    func freshConnectResetsAttempts() {
        let (c, s) = client()
        c.setReconnectAttemptsForTesting(5)

        c.connect(settings: s)

        #expect(c.reconnectAttempts == 0, "a new connection starts a fresh schedule")
    }

    @Test("delay grows with each attempt")
    func delayGrows() {
        let delays = (1...MQTTClient.maxReconnectAttempts).map { MQTTClient.backoffDelay(forAttempt: $0) }

        #expect(delays[0] == 0.25, "first retry is fast — the fault it recovers from is short")
        #expect(delays == delays.sorted(), "each retry waits at least as long as the last")
    }

    /// The whole retry chain must finish before the next scheduled sync, or the two
    /// overlap: the pre-flight starts a connection while a retry is queued, cancelling
    /// it and restarting the schedule, so it never reaches its limit. Keeping the chain
    /// shorter than the *minimum* interval makes that impossible at any configuration.
    @Test("the entire chain finishes within one scheduler interval")
    func chainFitsInsideASchedulerInterval() {
        let total = (1...MQTTClient.maxReconnectAttempts)
            .map { MQTTClient.backoffDelay(forAttempt: $0) }
            .reduce(0, +)

        #expect(total < 60, "minimum sync interval is 60s; the chain must end before then")
    }
}

/// Reconnection has two possible drivers — the backoff chain and the scheduler's
/// pre-flight — and they must not both drive it. If the pre-flight starts a connection
/// while a retry is already pending, it cancels that retry and resets the counter, so
/// the schedule restarts every sync cycle and never reaches its limit.
@Suite("Who owns reconnection")
struct ConnectionOwnershipTests {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test("does nothing when already connected")
    func connectedNeedsNothing() {
        #expect(MQTTClient.shouldStartNewConnection(
            state: .connected, retryPending: false, connectingSince: nil, now: t0) == false)
    }

    @Test("leaves a pending retry alone")
    func pendingRetryOwnsIt() {
        #expect(MQTTClient.shouldStartNewConnection(
            state: .connecting, retryPending: true, connectingSince: t0, now: t0) == false,
            "starting one here cancels the retry and resets its schedule")
    }

    @Test("takes over once the retry chain has given up")
    func exhaustedChainHandsBack() {
        #expect(MQTTClient.shouldStartNewConnection(
            state: .disconnected, retryPending: false, connectingSince: nil, now: t0) == true,
            "nothing else is trying, so the sync run must start it")
    }

    @Test("waits for an attempt that is genuinely in flight")
    func inFlightAttemptIsLeftAlone() {
        #expect(MQTTClient.shouldStartNewConnection(
            state: .connecting, retryPending: false,
            connectingSince: t0, now: t0.addingTimeInterval(2)) == false)
    }

    @Test("replaces an attempt that has stalled")
    func stalledAttemptIsReplaced() {
        #expect(MQTTClient.shouldStartNewConnection(
            state: .connecting, retryPending: false,
            connectingSince: t0, now: t0.addingTimeInterval(30)) == true,
            "a wedged .connecting must not block reconnection forever")
    }
}
