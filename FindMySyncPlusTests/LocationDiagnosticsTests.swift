import XCTest
@testable import FindMySyncPlus

/// "Why is this device blank in Home Assistant" is the most common question a user
/// has, and it is answerable in the app with no export and no round trip.
///
/// The line that existed said only "has no location", at `.debug` — which, because the
/// level check runs before the autoclosure, means it was never built at the default
/// level and so did not exist for anyone who had not changed the level picker.
///
/// Two buckets only, because two is all the data supports. There is deliberately no
/// "sharing disabled" bucket: `locationCapable`, `locationEnabled` and
/// `locFoundEnabled` were measured on #19 and do **not** track Share My Location — the
/// four devices that gained a position never changed a flag. A bucket built on them
/// would be a guess wearing a fact's clothing.
final class LocationDiagnosticsTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func millis(hoursAgo: Double) -> NSNumber {
        NSNumber(value: Int64((now.timeIntervalSince1970 - hoursAgo * 3600) * 1000))
    }

    private func locationDict(hoursAgo: Double, isOld: Bool, type: String) -> [String: Any] {
        ["latitude": 1.0, "longitude": 2.0, "horizontalAccuracy": 13.7,
         "timeStamp": millis(hoursAgo: hoursAgo), "isOld": isOld, "positionType": type]
    }

    // MARK: - Outcomes

    func testLocatedReportsWhatAppleSaidAboutTheFix() throws {
        let outcome = CacheDecryptor.locationOutcome(
            for: ["location": locationDict(hoursAgo: 0.5, isOld: false, type: "Wifi")], now: now)

        guard case let .located(type, accuracy, age) = outcome else {
            return XCTFail("expected located, got \(outcome)")
        }
        XCTAssertEqual(type, "Wifi")
        XCTAssertEqual(accuracy, 13.7)
        XCTAssertEqual(try XCTUnwrap(age), 0.5, accuracy: 0.01)
    }

    /// A record the fallback rescues is *located*, not "declined" — the diagnostic has
    /// to agree with what the parser actually did, or it reports a device as blank
    /// while Home Assistant shows it on the map.
    func testRescuedRecordCountsAsLocated() {
        let outcome = CacheDecryptor.locationOutcome(for: [
            "location": "$null",
            "crowdSourcedLocation": locationDict(hoursAgo: 0.1, isOld: false, type: "crowdsourced")
        ], now: now)

        guard case let .located(type, _, _) = outcome else {
            return XCTFail("expected located, got \(outcome)")
        }
        XCTAssertEqual(type, "crowdsourced")
    }

    func testDeclinedSightingReportsItsAge() throws {
        let outcome = CacheDecryptor.locationOutcome(for: [
            "location": "$null",
            "crowdSourcedLocation": locationDict(hoursAgo: 19.4, isOld: true, type: "crowdsourced")
        ], now: now)

        guard case let .cachedSightingDeclined(age) = outcome else {
            return XCTFail("expected cachedSightingDeclined, got \(outcome)")
        }
        XCTAssertEqual(try XCTUnwrap(age), 19.4, accuracy: 0.01)
    }

    func testNothingReportedWhenAppleHasNoPositionAtAll() {
        XCTAssertEqual(CacheDecryptor.locationOutcome(for: ["location": "$null"], now: now),
                       .nothingReported)
        XCTAssertEqual(CacheDecryptor.locationOutcome(for: [:], now: now), .nothingReported)
    }

    // MARK: - Age formatting

    /// Fractions of an hour read badly at both ends: a three-minute-old fix shows as
    /// `0.0h`, which looks like missing data rather than "just now".
    func testAgeReadsAsHoursAndMinutes() {
        XCTAssertEqual(SyncEngine.ageDescription(0.05), "0h3m")
        XCTAssertEqual(SyncEngine.ageDescription(1.0), "1h0m")
        XCTAssertEqual(SyncEngine.ageDescription(19.4), "19h24m")
        XCTAssertEqual(SyncEngine.ageDescription(0), "0h0m")
    }

    /// A timestamp in the future means clock skew somewhere. Keep it visible rather
    /// than clamping it to zero, which would disguise the anomaly as a fresh fix.
    func testFutureTimestampStaysVisible() {
        XCTAssertEqual(SyncEngine.ageDescription(-0.08), "-0h5m")
    }

    // MARK: - The summary line

    /// One `.info` line per source per run, not one per device: at 288 runs a day a
    /// per-device line would turn the 5000-entry buffer over in hours.
    func testSummaryNamesBothBuckets() throws {
        let line = try XCTUnwrap(SyncEngine.noLocationSummary(
            source: "Devices", total: 39, cachedOnly: 2, nothingReported: 10))

        XCTAssertTrue(line.hasPrefix("Devices: 12 of 39 have no location"), line)
        XCTAssertTrue(line.contains("2 with only a cached sighting"), line)
        XCTAssertTrue(line.contains("10 with nothing reported"), line)
    }

    /// Guidance, not a finding: no readable field tracks any of these settings.
    ///
    /// Deliberately generic. An earlier draft named Share My Location, since switching
    /// that on is what resolved #19 — but it governs sharing with *people*, while
    /// whether a device reports its own position depends on Location Services and the
    /// Find My iPhone/Mac toggle. Naming one switch on one machine's evidence would
    /// send everyone else to check the wrong thing.
    func testSettingsHintAccompaniesUnexplainedRecords() throws {
        let line = try XCTUnwrap(SyncEngine.noLocationSummary(
            source: "Devices", total: 39, cachedOnly: 2, nothingReported: 10))

        XCTAssertTrue(line.contains("location and sharing settings"), line)
        XCTAssertTrue(line.contains("offline"), line)
        XCTAssertFalse(line.contains("Share My Location"),
                       "one setting on one machine's evidence is not a diagnosis")
        XCTAssertFalse(line.contains("powered off"),
                       "an off device is offline; saying both is filler")
    }

    /// An all-blank source briefly had its own line blaming a stale cache. That is
    /// wrong — a stale cache holds *old* coordinates, not missing ones, so it shows as
    /// old timestamps rather than as no position at all. The general line reads
    /// correctly at any count, including all of them.
    func testAllBlankUsesTheSameLine() throws {
        let line = try XCTUnwrap(SyncEngine.noLocationSummary(
            source: "Devices", total: 39, cachedOnly: 0, nothingReported: 39))

        XCTAssertTrue(line.contains("39 of 39"), line)
        XCTAssertTrue(line.contains("location and sharing settings"), line)
        XCTAssertFalse(line.contains("cache"),
                       "a stale cache would show old coordinates, not missing ones")
    }

    /// Suppressed when every unlocated record has an explanation of its own, so the
    /// hint does not follow a run it cannot apply to.
    func testNoHintWhenEveryRecordIsExplained() throws {
        let line = try XCTUnwrap(SyncEngine.noLocationSummary(
            source: "Devices", total: 39, cachedOnly: 3, nothingReported: 0))

        XCTAssertFalse(line.contains("Share My Location"), line)
        XCTAssertTrue(line.contains("3 with only a cached sighting"), line)
    }

    func testNoSummaryWhenEverythingIsLocated() {
        XCTAssertNil(SyncEngine.noLocationSummary(
            source: "Devices", total: 39, cachedOnly: 0, nothingReported: 0))
    }
}
