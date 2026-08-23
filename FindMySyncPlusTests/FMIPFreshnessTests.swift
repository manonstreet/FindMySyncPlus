import Testing
import Foundation
@testable import FindMySyncPlus

/// Issue #17 asks for entities to update only when Find My actually updated them.
/// `location_timestamp` looked like it already shipped — `buildAttributes` publishes
/// it — but it is sourced from `richAttributes`, and those are built in exactly one
/// place: the friends path in `LocalStorageDecryptor`. Devices and Items acquire
/// them only by being merged from a matching friend record, and an AirTag has none.
///
/// So an Item reached Home Assistant with no timestamp at all — and #17's reporter
/// stated on #16 that Items are all they use. The data was already in the FMIP
/// cache: `SyncEngine` reads `timeStamp` and `isOld` for the grouped-parent
/// backfill and then discards them.
@Suite("FMIP location freshness")
struct FMIPFreshnessTests {

    private func raw(ts: Double?, isOld: Bool?) -> [String: Any] {
        var location: [String: Any] = [
            "latitude": 1.0,
            "longitude": 2.0,
            "horizontalAccuracy": 3.0
        ]
        if let ts { location["timeStamp"] = ts }
        if let isOld { location["isOld"] = isOld }

        return [
            "baUUID": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            "name": "Test AirTag",
            "location": location
        ]
    }

    @Test("an item with a location gets a timestamp")
    func itemGetsTimestamp() throws {
        let points = CacheDecryptor().parseDeviceArray([raw(ts: 1_600_000_000_000, isOld: false)])
        let rich = try #require(points.first?.richAttributes)

        #expect(rich.timestamp == Date(timeIntervalSince1970: 1_600_000_000))
    }

    @Test("isOld is carried through")
    func carriesIsOld() throws {
        let points = CacheDecryptor().parseDeviceArray([raw(ts: 1_600_000_000_000, isOld: true)])

        #expect(try #require(points.first?.richAttributes).isOld == true)
    }

    /// A false isOld is a positive statement from Apple that the fix is current.
    /// Folding it into nil would make it indistinguishable from Apple saying nothing.
    @Test("a false isOld is preserved, not folded into nil")
    func falseIsNotNil() throws {
        let points = CacheDecryptor().parseDeviceArray([raw(ts: 1_600_000_000_000, isOld: false)])

        #expect(try #require(points.first?.richAttributes).isOld == false)
    }

    /// Apple has omitted fields before. A missing timeStamp must not fabricate one,
    /// and must not cost us the device.
    @Test("a missing timeStamp yields no timestamp but keeps the device")
    func missingTimestamp() throws {
        let points = CacheDecryptor().parseDeviceArray([raw(ts: nil, isOld: true)])

        #expect(points.count == 1, "a missing timestamp must not drop the device")
        #expect(points.first?.richAttributes?.timestamp == nil)
        #expect(points.first?.richAttributes?.isOld == true, "isOld still stands on its own")
    }
}

/// A family device appears in both caches: FMIP supplies the location plus the
/// freshness fields above, and the friend record in LocalStorage supplies the
/// richer ones — altitude, speed, course, motion state, location label.
///
/// `SyncEngine` used to overwrite the device's attributes with the friend's
/// wholesale, guarded on `richAttributes == nil`. Once FMIP devices always carry
/// attributes that guard can never fire, and family devices would silently lose
/// every friend-derived field. The whole suite stayed green while that was true,
/// which is why this merge is pinned rather than left to the guard.
@Suite("Rich attribute merge")
struct RichAttributeMergeTests {

    private func fmip(timestamp: Date?, isOld: Bool?) -> RichLocationAttributes {
        RichLocationAttributes(verticalAccuracy: nil, altitude: nil, speed: nil,
                               course: nil, timestamp: timestamp,
                               motionActivityState: nil, locationLabel: nil,
                               isOld: isOld)
    }

    private func friend(altitude: Double?, motion: Int?, timestamp: Date?) -> RichLocationAttributes {
        RichLocationAttributes(verticalAccuracy: 5, altitude: altitude, speed: 1.5,
                               course: 90, timestamp: timestamp,
                               motionActivityState: motion, locationLabel: "Home",
                               isOld: nil)
    }

    /// The regression this exists to prevent.
    @Test("the friend's richer fields survive the merge")
    func friendFieldsWin() {
        let merged = fmip(timestamp: Date(timeIntervalSince1970: 100), isOld: false)
            .mergedPreferring(friend(altitude: 42, motion: 2, timestamp: nil))

        #expect(merged.altitude == 42)
        #expect(merged.speed == 1.5)
        #expect(merged.course == 90)
        #expect(merged.verticalAccuracy == 5)
        #expect(merged.motionActivityState == 2)
        #expect(merged.locationLabel == "Home")
    }

    /// The friend record has no isOld — only FMIP reports it — so ours must not be
    /// wiped out by a wholesale replacement.
    @Test("FMIP freshness survives when the friend record lacks it")
    func fmipFreshnessSurvives() {
        let merged = fmip(timestamp: Date(timeIntervalSince1970: 100), isOld: true)
            .mergedPreferring(friend(altitude: 42, motion: 2, timestamp: nil))

        #expect(merged.isOld == true)
        #expect(merged.timestamp == Date(timeIntervalSince1970: 100))
    }

    /// Where both have a value the friend record wins, preserving the behaviour
    /// that existed before FMIP devices carried attributes at all.
    @Test("the friend's timestamp wins when it has one")
    func friendTimestampWins() {
        let merged = fmip(timestamp: Date(timeIntervalSince1970: 100), isOld: false)
            .mergedPreferring(friend(altitude: nil, motion: nil,
                                     timestamp: Date(timeIntervalSince1970: 999)))

        #expect(merged.timestamp == Date(timeIntervalSince1970: 999))
    }
}

/// Issue #17, option A: publish what Apple says about the fix and let the user
/// decide what counts as stale, rather than imposing a staleness rule of ours.
@Suite("MQTT freshness attributes")
@MainActor
struct FreshnessAttributeTests {

    private func attrs(isOld: Bool?, timestamp: Date?) -> [String: Any] {
        let rich = RichLocationAttributes(verticalAccuracy: nil, altitude: nil,
                                          speed: nil, course: nil,
                                          timestamp: timestamp,
                                          motionActivityState: nil,
                                          locationLabel: nil, isOld: isOld)
        let point = DevicePoint(id: "uuid", name: "Test AirTag",
                                latitude: 1, longitude: 2, accuracy: 3,
                                battery: nil, richAttributes: rich)
        return MQTTClient().buildAttributes(for: point, iso: ISO8601DateFormatter())
    }

    @Test("publishes is_old when Apple reports it")
    func publishesIsOld() {
        #expect(attrs(isOld: true, timestamp: Date())["is_old"] as? Bool == true)
    }

    /// A false is a positive statement that the fix is current, and is as useful to
    /// template against as a true. Omitting it would throw that away.
    @Test("publishes a false is_old rather than omitting it")
    func publishesFalse() {
        #expect(attrs(isOld: false, timestamp: Date())["is_old"] as? Bool == false)
    }

    /// Absent must stay absent: a fabricated false would claim Apple called the fix
    /// current, which is a different statement from Apple saying nothing.
    @Test("omits is_old entirely when absent")
    func omitsWhenAbsent() {
        #expect(attrs(isOld: nil, timestamp: Date())["is_old"] == nil)
    }

    /// Already published before this work, but only ever reached friends. It now
    /// reaches Items too, which is the half of #17 that actually affects the
    /// reporter — so it is worth pinning here rather than assuming.
    @Test("still publishes location_timestamp")
    func stillPublishesTimestamp() {
        let a = attrs(isOld: nil, timestamp: Date(timeIntervalSince1970: 1_600_000_000))

        #expect(a["location_timestamp"] as? String == "2020-09-13T12:26:40Z")
    }
}
