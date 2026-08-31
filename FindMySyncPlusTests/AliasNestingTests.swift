import XCTest
@testable import FindMySyncPlus

/// The Aliases list is flat, so a fully aliased pair shows as three unrelated rows
/// with nothing tying them together. That is what #22 reported, against our own
/// advertising that grouped accessories appear as a single entry.
///
/// The join is on a **persisted `parentAlias`, not the live `parentID`**. The Aliases
/// list is persisted config and holds rows for devices that did not report this cycle,
/// so joining it against a run-scoped UUID map would go flat for anything offline —
/// and UUIDs rotate, while aliases do not.
///
/// Every case below comes from a real system: the development Mac and mini were
/// measured directly, #19 and #22 from their posted dumps. Inventing plausible shapes
/// is what produced three separate fixture defects earlier in this release.
final class AliasNestingTests: XCTestCase {

    private func alias(_ name: String, parent: String? = nil) -> DeviceAlias {
        DeviceAlias(alias: name, tracked: true, knownUUIDs: ["\(name)-uuid"],
                    lastSeenName: name, parentAlias: parent)
    }

    // MARK: - The shape the development Mac produces

    /// One parent, three children, all aliased — the group this Mac joins, where
    /// `itemGroup` is embedded in the parent's device record.
    func testAllAliasedNestsUnderTheParent() throws {
        let rows = [
            alias("airpods"),
            alias("case", parent: "airpods"),
            alias("left-bud", parent: "airpods"),
            alias("right-bud", parent: "airpods"),
            alias("phone")
        ]

        let partition = AliasPartition(rows)

        XCTAssertEqual(partition.topLevel.map(\.alias), ["airpods", "phone"])
        XCTAssertEqual(partition.children(of: "airpods").map(\.alias),
                       ["case", "left-bud", "right-bud"])
        XCTAssertTrue(partition.children(of: "phone").isEmpty)
    }

    // MARK: - The shape #22 actually reported

    /// His aliases were `ohrapfel-case` and `ohrapfel-left-bud` — **children aliased,
    /// the parent never**. So `parentAlias` names a row that is not in the list, and
    /// the children must appear as ordinary top-level rows rather than vanish.
    func testChildrenWhoseParentIsNotAliasedStayVisible() {
        let rows = [
            alias("ohrapfel-case", parent: "ohrapfel"),
            alias("ohrapfel-left-bud", parent: "ohrapfel"),
            alias("phone")
        ]

        let partition = AliasPartition(rows)

        XCTAssertEqual(partition.topLevel.map(\.alias),
                       ["ohrapfel-case", "ohrapfel-left-bud", "phone"],
                       "an orphan must never be hidden — it is a row the user created")
        XCTAssertTrue(partition.children(of: "ohrapfel").isEmpty)
    }

    // MARK: - The shape #19's dump produces

    /// Two independent groups, five children between them, all joining.
    func testTwoGroupsNestSeparately() {
        let rows = [
            alias("airpods"), alias("case", parent: "airpods"), alias("left", parent: "airpods"),
            alias("buds"), alias("bud-a", parent: "buds"), alias("bud-b", parent: "buds")
        ]

        let partition = AliasPartition(rows)

        XCTAssertEqual(partition.topLevel.map(\.alias), ["airpods", "buds"])
        XCTAssertEqual(partition.children(of: "airpods").map(\.alias), ["case", "left"])
        XCTAssertEqual(partition.children(of: "buds").map(\.alias), ["bud-a", "bud-b"])
    }

    // MARK: - The shape mini produces

    /// Measured on mini 2026-08-30: no device record carries an `itemGroup`, so the
    /// live join never happens and no child ever acquires a `parentAlias`. The list is
    /// flat, and that is correct rather than a failure — the group is unread there,
    /// not broken. Reading `ItemGroups.data` is `misc.md` §7, a separate decision.
    func testNoJoinObservedLeavesEverythingFlat() {
        let rows = [alias("case"), alias("left-bud"), alias("right-bud")]

        let partition = AliasPartition(rows)

        XCTAssertEqual(partition.topLevel.count, 3)
        XCTAssertTrue(partition.isFlat)
    }

    // MARK: - The unaliased group header

    /// #22's actual state: children aliased, the group never. `parentAlias` is written
    /// only when both ends are aliased, so these rows have none — and without a header
    /// they sit flat, which is the feature failing to reach the person who reported it.
    ///
    /// The header is drawn from the live grouping for this run, since there is no
    /// persisted value to read. That is sound rather than a compromise: an unaliased
    /// parent with no position of its own only reaches the list through revival, and
    /// revival needs a reporting child — so whenever a child is present to nest, the
    /// parent is present to nest under.
    func testUnaliasedParentBecomesAHeader() throws {
        let rows = [
            alias("ohrapfel-case"),
            alias("ohrapfel-left-bud"),
            alias("phone")
        ]
        let liveParents = ["ohrapfel-case": ("airpods-uuid", "AirPods Pro"),
                           "ohrapfel-left-bud": ("airpods-uuid", "AirPods Pro")]

        let partition = AliasPartition(rows, liveGroups: liveParents)

        let header = try XCTUnwrap(partition.headers.first)
        XCTAssertEqual(header.name, "AirPods Pro")
        XCTAssertEqual(partition.children(ofHeader: header.id).map(\.alias),
                       ["ohrapfel-case", "ohrapfel-left-bud"])
        XCTAssertEqual(partition.topLevel.map(\.alias), ["phone"],
                       "a child under a header is not also a top-level row")
    }

    /// The moment the group is aliased the header is gone and a real row takes its
    /// place — the upgrade-in-place the design promises. Nothing is drawn twice.
    func testAliasedParentReplacesTheHeader() {
        let rows = [
            alias("airpods"),
            alias("case", parent: "airpods"),
            alias("left-bud", parent: "airpods")
        ]
        let liveParents = ["case": ("airpods-uuid", "AirPods Pro"),
                           "left-bud": ("airpods-uuid", "AirPods Pro")]

        let partition = AliasPartition(rows, liveGroups: liveParents)

        XCTAssertTrue(partition.headers.isEmpty, "a real alias row supersedes the header")
        XCTAssertEqual(partition.topLevel.map(\.alias), ["airpods"])
        XCTAssertEqual(partition.children(of: "airpods").map(\.alias), ["case", "left-bud"])
    }

    /// Nothing reported this run — the mini shape, or simply an offline accessory. No
    /// live grouping means no header, and the rows stay flat rather than being hidden.
    func testNoLiveGroupingLeavesRowsFlat() {
        let rows = [alias("case"), alias("left-bud")]

        let partition = AliasPartition(rows, liveGroups: [:])

        XCTAssertTrue(partition.headers.isEmpty)
        XCTAssertEqual(partition.topLevel.count, 2)
    }

    /// A lone aliased child still gets its header: one is a group as much as three are,
    /// and suppressing it would make the list change shape as siblings are aliased.
    func testASingleChildStillGetsItsHeader() throws {
        let rows = [alias("case")]
        let partition = AliasPartition(rows, liveGroups: ["case": ("airpods-uuid", "AirPods Pro")])

        let header = try XCTUnwrap(partition.headers.first)
        XCTAssertEqual(partition.children(ofHeader: header.id).map(\.alias), ["case"])
    }

    // MARK: - Ordering and defence

    /// Nesting imposes an order, and the existing list is sorted by name. Children keep
    /// name order within their parent so a row does not move between runs.
    func testChildrenKeepNameOrderWithinAParent() {
        let rows = [alias("airpods"), alias("zulu", parent: "airpods"), alias("alpha", parent: "airpods")]

        XCTAssertEqual(AliasPartition(rows).children(of: "airpods").map(\.alias), ["alpha", "zulu"])
    }

    /// A parent naming itself, or a cycle, must not hang or drop rows. Nothing observed
    /// produces this; it is cheap to make impossible rather than to reason about.
    func testSelfReferenceAndCyclesDoNotLoseRows() {
        let selfRef = [alias("airpods", parent: "airpods")]
        XCTAssertEqual(AliasPartition(selfRef).topLevel.map(\.alias), ["airpods"])

        let cycle = [alias("a", parent: "b"), alias("b", parent: "a")]
        let partition = AliasPartition(cycle)
        XCTAssertEqual(partition.topLevel.count + partition.children(of: "a").count
                       + partition.children(of: "b").count, 2,
                       "every row appears exactly once, wherever it lands")
    }

    /// Grandchildren are not a thing Apple produces, and the list renders one level.
    /// A child naming a child is flattened rather than nested two deep.
    func testOnlyOneLevelOfNesting() {
        let rows = [alias("airpods"), alias("case", parent: "airpods"),
                    alias("tip", parent: "case")]

        let partition = AliasPartition(rows)

        XCTAssertEqual(partition.children(of: "airpods").map(\.alias), ["case"])
        XCTAssertTrue(partition.topLevel.contains { $0.alias == "tip" },
                      "a second level is flattened to top level, not hidden")
    }

    // MARK: - Persistence

    /// `parentAlias` absent must decode to nil, so no migration is needed for the
    /// aliases already on every user's machine.
    func testLegacyAliasWithoutParentDecodes() throws {
        let json = #"{"alias":"keys","tracked":true,"knownUUIDs":["abc"],"lastSeenName":"Keys"}"#
        let decoded = try JSONDecoder().decode(DeviceAlias.self, from: Data(json.utf8))

        XCTAssertNil(decoded.parentAlias)
        XCTAssertEqual(decoded.alias, "keys")
    }

    func testParentAliasRoundTrips() throws {
        let original = alias("case", parent: "airpods")
        let decoded = try JSONDecoder().decode(
            DeviceAlias.self, from: try JSONEncoder().encode(original))

        XCTAssertEqual(decoded.parentAlias, "airpods")
    }

    /// Absent stays absent on the way out too, so an alias that never joined a group
    /// does not gain a null key in stored config.
    func testNoParentIsNotEncoded() throws {
        let data = try JSONEncoder().encode(alias("phone"))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(text.contains("parentAlias"), text)
    }
}
