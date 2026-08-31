import XCTest
@testable import FindMySyncPlus

/// Friend locations require macOS 15 or later: on macOS 14 the Find My app itself
/// has no location for shared people, so there is nothing to read.
///
/// No macOS 14 machine exists to test on, so the version is injected at the point of
/// decision rather than read from `ProcessInfo` there. `resolve` is pure so these can
/// exercise the 14.x branch without writing to the app's real `UserDefaults` — the
/// test target is hosted by the app bundle, so a write here would land in the user's
/// own configuration.
final class FriendsAvailabilityTests: XCTestCase {

    private func version(_ major: Int, _ minor: Int, _ patch: Int) -> OperatingSystemVersion {
        OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch)
    }

    // MARK: - The predicate

    func testUnsupportedOnSonoma() {
        XCTAssertFalse(FriendsAvailability(osVersion: version(14, 8, 9)).isSupported)
        XCTAssertFalse(FriendsAvailability(osVersion: version(14, 4, 0)).isSupported)
    }

    func testSupportedOnSequoiaAndLater() {
        XCTAssertTrue(FriendsAvailability(osVersion: version(15, 0, 0)).isSupported)
        XCTAssertTrue(FriendsAvailability(osVersion: version(15, 7, 2)).isSupported)
        XCTAssertTrue(FriendsAvailability(osVersion: version(26, 5, 2)).isSupported)
    }

    // MARK: - The version the status log reports

    /// The status line names the running version, because that is the fact a reporter
    /// would otherwise be asked for.
    func testVersionDescriptionNamesTheRunningVersion() {
        XCTAssertEqual(FriendsAvailability(osVersion: version(14, 8, 9)).versionDescription, "14.8.9")
        XCTAssertEqual(FriendsAvailability(osVersion: version(15, 0, 0)).versionDescription, "15.0.0")
    }

    // MARK: - The spoof override

    func testNoSpoofUsesTheRunningVersion() {
        let availability = FriendsAvailability.resolve(spoof: nil, actual: version(26, 5, 2))
        XCTAssertTrue(availability.isSupported)
        XCTAssertEqual(availability.versionDescription, "26.5.2")
        XCTAssertFalse(availability.isSpoofed)
    }

    func testEmptySpoofUsesTheRunningVersion() {
        let availability = FriendsAvailability.resolve(spoof: "", actual: version(26, 5, 2))
        XCTAssertTrue(availability.isSupported)
        XCTAssertFalse(availability.isSpoofed)
    }

    func testSpoofOverridesTheRunningVersion() {
        let availability = FriendsAvailability.resolve(spoof: "14.8.9", actual: version(26, 5, 2))
        XCTAssertFalse(availability.isSupported)
        XCTAssertEqual(availability.versionDescription, "14.8.9")
        XCTAssertTrue(availability.isSpoofed)
    }

    func testSpoofAcceptsPartialVersions() {
        XCTAssertEqual(
            FriendsAvailability.resolve(spoof: "14", actual: version(26, 5, 2)).versionDescription,
            "14.0.0")
        XCTAssertEqual(
            FriendsAvailability.resolve(spoof: "15.7", actual: version(26, 5, 2)).versionDescription,
            "15.7.0")
    }

    // MARK: - The engine gate

    /// The switch alone is not enough. A stored `enableFriends = true` can arrive from
    /// a machine that was upgraded, or from synced defaults, so the engine applies the
    /// version check itself rather than trusting the toggle's state.
    func testStoredToggleDoesNotEnableFriendsOnSonoma() {
        let sonoma = FriendsAvailability(osVersion: version(14, 8, 9))
        XCTAssertFalse(sonoma.isEnabled(userToggle: true))
        XCTAssertFalse(sonoma.isEnabled(userToggle: false))
    }

    func testToggleDecidesFriendsOnSupportedVersions() {
        let sequoia = FriendsAvailability(osVersion: version(15, 7, 2))
        XCTAssertTrue(sequoia.isEnabled(userToggle: true))
        XCTAssertFalse(sequoia.isEnabled(userToggle: false))
    }

    // MARK: - Key indicators

    /// The FMF and LocalStorage keys serve Friends only. When Friends cannot run, their
    /// indicators would sit permanently unresolved — the complaint on #19 — so they read
    /// "not applicable" rather than as a warning the user has no way to clear.
    /// The macOS reason outranks the toggle, because it is the one the user cannot act
    /// on: telling someone on macOS 14 that Friends is merely switched off would send
    /// them to flip a switch that is disabled.
    func testMacOSReasonOutranksTheToggle() {
        let sonoma = FriendsAvailability(osVersion: version(14, 8, 9))
        XCTAssertEqual(sonoma.keyApplicability(userToggle: true), .needsNewerOS)
        XCTAssertEqual(sonoma.keyApplicability(userToggle: false), .needsNewerOS)
    }

    func testSwitchedOffIsNamedAsSuchOnSupportedVersions() {
        let sequoia = FriendsAvailability(osVersion: version(15, 7, 2))
        XCTAssertEqual(sequoia.keyApplicability(userToggle: false), .friendsOff)
    }

    func testFriendsOnlyKeysReportWhenFriendsCanRun() {
        let sequoia = FriendsAvailability(osVersion: version(15, 7, 2))
        XCTAssertEqual(sequoia.keyApplicability(userToggle: true), .reported)
        XCTAssertNil(KeyApplicability.reported.label)
    }

    /// The indicator has to stand on its own, since there is no longer a paragraph
    /// above the section explaining it — but the row is name-then-status with the
    /// window free to narrow, so the label has to stay short enough not to wrap on
    /// `LocalStorage`, the longest of the three names.
    func testNotApplicableLabelsNameTheirReasonTersely() {
        XCTAssertEqual(KeyApplicability.needsNewerOS.label, "Needs macOS 15")
        XCTAssertEqual(KeyApplicability.friendsOff.label, "Friends off")

        // The Friends toggle and the key indicators live on different settings tabs and
        // are worded for their own slot, but both name the version from the predicate,
        // so the copy cannot outlive a change to the gate.
        XCTAssertEqual(KeyApplicability.needsNewerOS.label, FriendsAvailability.shortRestriction)
        XCTAssertEqual(FriendsAvailability.minimumVersionName, "macOS 15")
        XCTAssertTrue(FriendsAvailability.shortRestriction.contains(FriendsAvailability.minimumVersionName))
        XCTAssertTrue(FriendsAvailability.toggleQualifier.contains(FriendsAvailability.minimumVersionName))
        XCTAssertEqual(FriendsAvailability.toggleQualifier, "needs macOS 15")

        for state in [KeyApplicability.needsNewerOS, .friendsOff] {
            XCTAssertLessThanOrEqual(state.label?.count ?? 0, 16, "\(state) would wrap the row")
        }
    }

    /// A typo must not silently disable a working feature, so a value that does not
    /// parse falls back to the running version rather than gating Friends off.
    func testMalformedSpoofFallsBackToTheRunningVersion() {
        for garbage in ["not-a-version", "14.x", "..", "-1"] {
            let availability = FriendsAvailability.resolve(spoof: garbage, actual: version(26, 5, 2))
            XCTAssertTrue(availability.isSupported, "\(garbage) should not gate Friends off")
            XCTAssertEqual(availability.versionDescription, "26.5.2")
            XCTAssertFalse(availability.isSpoofed, "\(garbage) is not an active spoof")
        }
    }
}
