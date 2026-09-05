import Testing
import Foundation
@testable import FindMySyncPlus

/// Accessory records without a `baUUID` fall through the id chain to `deviceDiscoveryId`,
/// which is a Bluetooth MAC. Two records for one physical accessory then land on the same
/// id and both publish to the same entity in a single run — Home Assistant renders one and
/// the other overwrites it a moment later. Issue #27.
///
/// The tie-break is the reporter's own observation rather than a guess: the primary user's
/// location is the correct one, and Apple writes `prsId` as the literal `"owner"` for this
/// account against a DSID for a family member's copy.
///
/// It cannot key on the identifier, which is identical across the candidates by definition
/// — that is what made them collide.
@Suite("Duplicate identity")
@MainActor
struct DuplicateIdentityTests {

    private static let sharedID = "24:F6:77:BC:53:DA"
    private static let base = Date(timeIntervalSince1970: 1_600_000_000)

    private func record(_ name: String, prsId: String?, offset: TimeInterval = 0,
                        id: String = sharedID, type: String? = "Wifi") -> DevicePoint {
        DevicePoint(id: id, name: name,
                    latitude: 40.4, longitude: -74.8, accuracy: 25,
                    battery: nil, prsId: prsId,
                    richAttributes: RichLocationAttributes(
                        verticalAccuracy: nil, altitude: nil, speed: nil, course: nil,
                        timestamp: Self.base.addingTimeInterval(offset),
                        motionActivityState: nil, locationLabel: nil,
                        positionType: type))
    }

    // MARK: - the rule

    /// #27's shape. The family member's copy reported later, and still loses.
    @Test("this account's own record wins over a family member's, however fresh")
    func ownerBeatsFamily() {
        let result = SyncEngine.dedupeByEntity([
            record("AirPods Max", prsId: "family-dsid", offset: 600),
            record("AirPods Max", prsId: "owner")
        ])
        #expect(result.points.count == 1)
        #expect(result.points.first?.prsId == "owner")
    }

    /// Measured on the development Mac: one accessory shared through iCloud Family appears
    /// three times, every candidate a DSID and none of them `owner`. The fall-through is
    /// what decides this, so it is not defensive padding.
    @Test("with no owner among the candidates the freshest wins")
    func noOwnerFallsBackToFreshest() {
        let result = SyncEngine.dedupeByEntity([
            record("Meg's AirPods", prsId: "person-a"),
            record("Meg's AirPods", prsId: "person-b", offset: 900),
            record("Friedman AirPods", prsId: "person-c", offset: 300)
        ])
        #expect(result.points.count == 1)
        #expect(result.points.first?.prsId == "person-b")
    }

    @Test("among several owner records the freshest wins")
    func severalOwnersTakeFreshest() {
        let result = SyncEngine.dedupeByEntity([
            record("AirPods", prsId: "owner"),
            record("AirPods", prsId: "owner", offset: 500)
        ])
        #expect(result.points.count == 1)
        #expect(result.points.first?.richAttributes?.timestamp
                == Self.base.addingTimeInterval(500))
    }

    /// The choice must not vary between runs — that would be the flapping again by another
    /// route. Equal timestamps fall to `prsId`, which differs because the records belong to
    /// different people.
    @Test("equal timestamps resolve by prsId, the same way every run")
    func tieResolvesDeterministically() {
        let forwards = SyncEngine.dedupeByEntity([
            record("AirPods", prsId: "person-b"),
            record("AirPods", prsId: "person-a")
        ])
        let backwards = SyncEngine.dedupeByEntity([
            record("AirPods", prsId: "person-a"),
            record("AirPods", prsId: "person-b")
        ])
        #expect(forwards.points.first?.prsId == "person-a")
        #expect(backwards.points.first?.prsId == "person-a")
    }

    // MARK: - what it leaves alone

    @Test("records with distinct ids are untouched and keep their order")
    func noCollisionChangesNothing() {
        let points = [record("A", prsId: "owner", id: "id-a"),
                      record("B", prsId: "owner", id: "id-b"),
                      record("C", prsId: "owner", id: "id-c")]
        let result = SyncEngine.dedupeByEntity(points)
        #expect(result.points.map(\.name) == ["A", "B", "C"])
        #expect(result.collisions.isEmpty)
    }

    /// Two records differing only in case of the identifier are the same entity, because
    /// the alias lookup normalizes before matching.
    @Test("the comparison is on the normalized id, as the entity lookup is")
    func normalizedComparison() {
        let result = SyncEngine.dedupeByEntity([
            record("AirPods", prsId: "owner", id: "AA:BB:CC"),
            record("AirPods", prsId: "family", id: "aa:bb:cc")
        ])
        #expect(result.points.count == 1)
    }

    @Test("surviving records keep the order they were read in")
    func orderPreserved() {
        let result = SyncEngine.dedupeByEntity([
            record("First", prsId: "owner", id: "id-a"),
            record("Dupe", prsId: "family", id: Self.sharedID),
            record("Last", prsId: "owner", id: "id-z"),
            record("Dupe", prsId: "owner", id: Self.sharedID)
        ])
        #expect(result.points.map(\.name) == ["First", "Last", "Dupe"])
    }

    // MARK: - what it reports
    //
    // Both sides are needed: the reporter's next run is what tells us whether the rule
    // chose correctly, and that is unanswerable from the winner alone.

    @Test("a collision reports what was kept and what was dropped")
    func collisionReportsBothSides() {
        let result = SyncEngine.dedupeByEntity([
            record("AirPods Max", prsId: "owner", type: "Wifi"),
            record("AirPods Max", prsId: "family-dsid", offset: 600, type: "crowdsourced")
        ])
        let collision = result.collisions.first
        #expect(result.collisions.count == 1)
        #expect(collision?.entity == Self.sharedID.normalized())
        #expect(collision?.kept.prsId == "owner")
        #expect(collision?.dropped.count == 1)
        #expect(collision?.dropped.first?.prsId == "family-dsid")
    }

    /// Every other device line prints the id as written, so this one does too.
    @Test("the log line uses the id as written, not the normalized key")
    func logUsesTheWrittenID() {
        let line = SyncEngine.collisionDescription(record("AirPods", prsId: "owner"))
        #expect(!line.contains("24f677bc53da"))
    }

    @Test("the log line names the ownership, position type and age of both")
    func descriptionCarriesTheDiscriminators() {
        let line = SyncEngine.collisionDescription(
            record("AirPods Max", prsId: "family-dsid", type: "crowdsourced"))
        #expect(line.contains("AirPods Max"))
        #expect(line.contains("family"))
        #expect(line.contains("crowdsourced"))
    }

    @Test("a record with no prsId reads as unowned rather than as this account's")
    func missingPrsIdIsNotOwner() {
        let line = SyncEngine.collisionDescription(record("AirPods", prsId: nil))
        #expect(line.contains("unowned"))
    }

    @Test("no collision reports nothing")
    func quietWhenClean() {
        let result = SyncEngine.dedupeByEntity([record("A", prsId: "owner", id: "id-a")])
        #expect(result.collisions.isEmpty)
    }
}
