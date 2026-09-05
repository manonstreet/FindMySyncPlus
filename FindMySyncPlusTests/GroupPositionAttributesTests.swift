import Testing
import Foundation
@testable import FindMySyncPlus

/// A group entity's position is sometimes its own record's and sometimes borrowed from a
/// piece, and until now nothing said which. While the pieces are together that hardly
/// matters — measured 5–6 m apart inside their own 24–30 m accuracy, so any one of them
/// represents the group. Separated, the group follows whichever piece reported last, which
/// can be the bud left at the office.
///
/// `position_source` says what the coordinate is. `separation_status` says whether that
/// piece stands for the group.
@Suite("Group position attributes")
@MainActor
struct GroupPositionAttributesTests {

    private static let parentID = "11111111-1111-1111-1111-111111111111"
    private static let interval: TimeInterval = 300
    private static let base = Date(timeIntervalSince1970: 1_600_000_000)

    private func child(_ name: String, lat: Double, lon: Double,
                       accuracy: Double = 25, offset: TimeInterval = 0,
                       address: String? = nil, dated: Bool = true) -> DevicePoint {
        DevicePoint(id: "\(name)-id", name: name,
                    latitude: lat, longitude: lon, accuracy: accuracy,
                    battery: nil,
                    richAttributes: RichLocationAttributes(
                        verticalAccuracy: nil, altitude: nil, speed: nil, course: nil,
                        timestamp: dated ? Self.base.addingTimeInterval(offset) : nil,
                        motionActivityState: nil, locationLabel: nil,
                        address: address),
                    parentID: Self.parentID)
    }

    private func parent(lat: Double, lon: Double, accuracy: Double = 25,
                        timestamp: Date? = base) -> DevicePoint {
        DevicePoint(id: Self.parentID, name: "AirPods Pro",
                    latitude: lat, longitude: lon, accuracy: accuracy,
                    battery: nil,
                    richAttributes: RichLocationAttributes(
                        verticalAccuracy: nil, altitude: nil, speed: nil, course: nil,
                        timestamp: timestamp, motionActivityState: nil, locationLabel: nil))
    }

    private func status(_ children: [DevicePoint]) -> String {
        SyncEngine().separationStatus(children: children, syncInterval: Self.interval)
    }

    // MARK: - distance, which is geometry rather than a tuned constant
    //
    // Compared child to child. Comparing against the group's own coordinate made the
    // status depend on a position that, once the status picks the anchor, depends on the
    // status.

    /// The measured real numbers — ~5 m apart, 25 m accuracy each, error circles overlapping.
    @Test("pieces within their combined accuracy read together")
    func together() {
        #expect(status([child("Case", lat: 43.0598, lon: -77.6425),
                        child("Left Bud", lat: 43.05985, lon: -77.6425)]) == "together")
    }

    /// Several hundred metres against a 50 m combined radius.
    @Test("a piece beyond the combined accuracy reads separated")
    func separated() {
        #expect(status([child("Case", lat: 43.0598, lon: -77.6425),
                        child("Right Bud", lat: 43.0650, lon: -77.6425)]) == "separated")
    }

    /// One separated piece is enough — the group cannot represent the whole set.
    @Test("one separated piece among several reads separated")
    func oneSeparatedIsEnough() {
        #expect(status([child("Case", lat: 43.0598, lon: -77.6425),
                        child("Left Bud", lat: 43.05985, lon: -77.6425),
                        child("Right Bud", lat: 43.0650, lon: -77.6425)]) == "separated")
    }

    /// Poor accuracy widens the circles, so the same distance stops being a disagreement.
    /// That is the point of testing against the radii rather than a fixed metre count.
    @Test("the threshold scales with reported accuracy")
    func thresholdScalesWithAccuracy() {
        #expect(status([child("Case", lat: 43.0598, lon: -77.6425, accuracy: 25),
                        child("Bud", lat: 43.0620, lon: -77.6425, accuracy: 25)]) == "separated")
        #expect(status([child("Case", lat: 43.0598, lon: -77.6425, accuracy: 400),
                        child("Bud", lat: 43.0620, lon: -77.6425, accuracy: 400)]) == "together")
    }

    /// A parent holding a stale position of its own used to read as separated from its own
    /// children. Comparing the pieces to each other removes the case entirely.
    @Test("a stale parent position cannot make its own pieces read separated")
    func staleParentDoesNotSeparateItsPieces() {
        let pieces = [child("Case", lat: 43.0598, lon: -77.6425),
                      child("Left Bud", lat: 43.05985, lon: -77.6425)]
        _ = parent(lat: 43.9999, lon: -77.9999, timestamp: Self.base.addingTimeInterval(-9_000))
        #expect(status(pieces) == "together")
    }

    // MARK: - comparability, which is about the pair rather than either record

    /// Fixes from different refresh cycles describe different moments. Several hundred
    /// metres between them says where a piece *was*, not that it is elsewhere now.
    @Test("positions from different refresh cycles are not comparable")
    func gapBeyondIntervalIsUnknown() {
        #expect(status([child("Case", lat: 43.0598, lon: -77.6425),
                        child("Right Bud", lat: 43.0650, lon: -77.6425,
                              offset: 3600)]) == "unknown")
    }

    /// Issue #28's shape: a position nearly three hours stale, which Apple still flagged
    /// `is_old: false`. Comparability does not consult that flag, so the gap alone settles it.
    @Test("a nearly three-hour gap reads unknown regardless of any staleness flag")
    func issue28Shape() {
        #expect(status([child("Case", lat: 43.0598, lon: -77.6425),
                        child("Bag", lat: 43.0598, lon: -77.6425,
                              offset: -9_900)]) == "unknown")
    }

    /// Inside the window the pieces are still comparable, so distance decides.
    @Test("a gap inside the interval still compares")
    func gapInsideIntervalCompares() {
        #expect(status([child("Case", lat: 43.0598, lon: -77.6425),
                        child("Left Bud", lat: 43.05985, lon: -77.6425,
                              offset: 120)]) == "together")
    }

    @Test("a piece with no timestamp leaves nothing to compare against")
    func undatedPieceIsUnknown() {
        #expect(status([child("Case", lat: 43.0598, lon: -77.6425),
                        child("Left Bud", lat: 43.05985, lon: -77.6425,
                              dated: false)]) == "unknown")
    }

    @Test("one piece, or none, reads unknown")
    func fewerThanTwoIsUnknown() {
        #expect(status([]) == "unknown")
        #expect(status([child("Case", lat: 43.0598, lon: -77.6425)]) == "unknown")
    }

    // MARK: - which piece the group borrows from
    //
    // Measured on a live cache: while separated, the freshest child flipped five times in
    // seventeen runs between points 766 m apart. Together, freshest cannot be wrong,
    // because every piece describes the same place.

    private func anchor(_ children: [DevicePoint], freshest: DevicePoint,
                        interval: TimeInterval? = Self.interval) -> String {
        SyncEngine().anchorChild(among: children, freshest: freshest,
                                 syncInterval: interval).name
    }

    @Test("while separated the group takes the case, not whichever piece is freshest")
    func separatedAnchorsToCase() {
        let caseP = child("Case", lat: 43.0598, lon: -77.6425)
        let bud = child("Right Bud", lat: 43.0650, lon: -77.6425, offset: 60)
        #expect(anchor([caseP, bud], freshest: bud) == "Case")
    }

    @Test("while together the group takes the freshest piece")
    func togetherAnchorsToFreshest() {
        let caseP = child("Case", lat: 43.0598, lon: -77.6425)
        let bud = child("Left Bud", lat: 43.05985, lon: -77.6425, offset: 60)
        #expect(anchor([caseP, bud], freshest: bud) == "Left Bud")
    }

    /// `name` is AirPods vocabulary. One product's values have been measured, so the rule
    /// falls back rather than guaranteeing.
    @Test("separated with no piece named Case falls back to freshest")
    func separatedWithoutACaseFallsBack() {
        let left = child("Left Bud", lat: 43.0598, lon: -77.6425)
        let right = child("Right Bud", lat: 43.0650, lon: -77.6425, offset: 60)
        #expect(anchor([left, right], freshest: right) == "Right Bud")
    }

    /// Callers that do not supply an interval keep the old behavior exactly.
    @Test("with no interval the rule is inert")
    func noIntervalKeepsFreshest() {
        let caseP = child("Case", lat: 43.0598, lon: -77.6425)
        let bud = child("Right Bud", lat: 43.0650, lon: -77.6425, offset: 60)
        #expect(anchor([caseP, bud], freshest: bud, interval: nil) == "Right Bud")
    }

    // MARK: - where the pieces are, published only while they are apart

    @Test("each piece is listed with its address and how old that is")
    func piecesCarryAddressAndAge() {
        let summaries = SyncEngine.pieceSummaries([
            child("Case", lat: 43.0598, lon: -77.6425, address: "9 Aaaaaaa Aa, Aaaaaaaaa"),
            child("Right Bud", lat: 43.0650, lon: -77.6425, address: "99 Aaaa Aa, Aaaaaa")
        ])
        let entries = try? #require(summaries)
        #expect(entries?.count == 2)
        #expect(entries?.first?["name"] == "Case")
        #expect(entries?.first?["address"] == "9 Aaaaaaa Aa, Aaaaaaaaa")
        #expect(entries?.first?["age"] != nil)
    }

    /// Not every record carries an address. The name and age are the useful half.
    @Test("a piece with no address is still listed")
    func pieceWithoutAddressStillListed() {
        let summaries = SyncEngine.pieceSummaries([
            child("Case", lat: 43.0598, lon: -77.6425)
        ])
        #expect(summaries?.count == 1)
        #expect(summaries?.first?["address"] == nil)
        #expect(summaries?.first?["age"] != nil)
    }

    /// A name on its own says nothing worth a payload.
    @Test("a piece with neither address nor age is dropped")
    func pieceWithNothingIsDropped() {
        #expect(SyncEngine.pieceSummaries([
            child("Case", lat: 43.0598, lon: -77.6425, dated: false)
        ]) == nil)
    }

    // MARK: - publishing

    private func point(source: String?, separation: String?,
                       pieces: [[String: String]]? = nil) -> DevicePoint {
        let rich = RichLocationAttributes(
            verticalAccuracy: nil, altitude: nil, speed: nil, course: nil,
            timestamp: nil, motionActivityState: nil, locationLabel: nil,
            positionSource: source, separationStatus: separation, pieces: pieces)
        return DevicePoint(id: "uuid", name: "AirPods Pro",
                           latitude: 1, longitude: 2, accuracy: 3,
                           battery: nil, richAttributes: rich)
    }

    @Test("both attributes reach the MQTT payload")
    func published() {
        let attrs = MQTTClient().buildAttributes(
            for: point(source: "Left Bud", separation: "separated"),
            iso: ISO8601DateFormatter())
        #expect(attrs["position_source"] as? String == "Left Bud")
        #expect(attrs["separation_status"] as? String == "separated")
    }

    @Test("an ungrouped device publishes neither")
    func ungroupedPublishesNeither() {
        let attrs = MQTTClient().buildAttributes(
            for: point(source: nil, separation: nil), iso: ISO8601DateFormatter())
        #expect(attrs["position_source"] == nil)
        #expect(attrs["separation_status"] == nil)
    }

    /// The distance is ours rather than Apple's, and a number invites thresholds built on
    /// an inference. The three-state string says exactly what is known.
    @Test("the computed distance is never published")
    func distanceNotPublished() {
        let attrs = MQTTClient().buildAttributes(
            for: point(source: "Case", separation: "together"), iso: ISO8601DateFormatter())
        #expect(attrs["separation_distance"] == nil)
        #expect(attrs["distance"] == nil)
    }

    @Test("the pieces reach the MQTT payload while separated")
    func piecesPublished() {
        let attrs = MQTTClient().buildAttributes(
            for: point(source: "Case", separation: "separated",
                       pieces: [["name": "Right Bud", "address": "99 Aaaa Aa", "age": "0h3m"]]),
            iso: ISO8601DateFormatter())
        let pieces = attrs["pieces"] as? [[String: String]]
        #expect(pieces?.count == 1)
        #expect(pieces?.first?["name"] == "Right Bud")
    }

    /// Its presence is the signal, so a group whose pieces are together carries no key.
    @Test("a group that is together publishes no pieces")
    func togetherPublishesNoPieces() {
        let attrs = MQTTClient().buildAttributes(
            for: point(source: "Case", separation: "together"), iso: ISO8601DateFormatter())
        #expect(attrs["pieces"] == nil)
    }
}
