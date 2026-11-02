import XCTest
@testable import FindMySyncPlus

final class FamilyFriendTrackingTests: XCTestCase {

    private let familyDSID = "FAMILY-PERSON-1234"

    func testDefaultPolicySuppressesFamilyFriend() {
        XCTAssertFalse(SyncEngine.shouldTrackFriend(
            id: familyDSID,
            familyDSIDs: [familyDSID.normalized()],
            trackFamilyMembersAsFriends: false))
    }

    func testOptInKeepsFamilyFriendAsPersonTracker() {
        XCTAssertTrue(SyncEngine.shouldTrackFriend(
            id: familyDSID,
            familyDSIDs: [familyDSID.normalized()],
            trackFamilyMembersAsFriends: true))
    }

    func testNonFamilyFriendIsAlwaysTracked() {
        for optIn in [false, true] {
            XCTAssertTrue(SyncEngine.shouldTrackFriend(
                id: "a-different-person",
                familyDSIDs: [familyDSID.normalized()],
                trackFamilyMembersAsFriends: optIn))
        }
    }

    func testComparisonNormalizesPersonIdentifiers() {
        XCTAssertFalse(SyncEngine.shouldTrackFriend(
            id: "AB-CD-EF",
            familyDSIDs: ["abcdef"],
            trackFamilyMembersAsFriends: false))
    }
}
