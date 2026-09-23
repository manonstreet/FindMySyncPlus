import Testing
@testable import FindMySyncPlus

/// The Unassigned split, which two parts of one screen read: the pane's list and the
/// sidebar's new-entity badge.
///
/// They ask different questions of the same entries on purpose. The list keeps an *aliased*
/// grouped parent visible so its unaliased children can nest under it; the badge counts what
/// nobody has aliased, so that same parent must not raise it. Both live here rather than in
/// `TrackingView`, because a private computed property on the view is unreachable from the
/// sidebar, and two implementations of "unassigned" would let the badge and the list tell
/// different stories.
@Suite("Unassigned partition")
struct UnassignedPartitionTests {

    private static let parent = "11111111111111111111111111111111"
    private static let childA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private static let childB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    private static let loose  = "cccccccccccccccccccccccccccccccc"

    private func entry(_ id: String, parentID: String? = nil,
                       source: DeviceSource = .item) -> LocatedEntry {
        LocatedEntry(point: DevicePoint(id: id, name: id, latitude: 1, longitude: 1,
                                        accuracy: 1, battery: nil, parentID: parentID),
                     source: source)
    }

    // MARK: - What the list shows

    @Test("An unaliased entry is listed")
    func unaliasedIsListed() {
        let listed = UnassignedPartition.listed(entries: [entry(Self.loose)], knownUUIDs: [])
        #expect(listed.map { $0.point.id } == [Self.loose])
    }

    @Test("An aliased entry with no unaliased children drops out of the list")
    func aliasedDropsOut() {
        let listed = UnassignedPartition.listed(entries: [entry(Self.loose)],
                                                knownUUIDs: [Self.loose])
        #expect(listed.isEmpty)
    }

    @Test("An aliased grouped parent stays listed while a child is unaliased")
    func aliasedParentStaysForItsChild() {
        let entries = [entry(Self.parent), entry(Self.childA, parentID: Self.parent)]
        let listed = UnassignedPartition.listed(entries: entries, knownUUIDs: [Self.parent])
        #expect(Set(listed.map { $0.point.id }) == [Self.parent, Self.childA])
    }

    @Test("An aliased grouped parent leaves the list once every child is aliased")
    func aliasedParentLeavesWhenChildrenAreAliased() {
        let entries = [entry(Self.parent), entry(Self.childA, parentID: Self.parent)]
        let listed = UnassignedPartition.listed(entries: entries,
                                                knownUUIDs: [Self.parent, Self.childA])
        #expect(listed.isEmpty)
    }

    // MARK: - What the badge counts

    @Test("An unaliased entry nobody has seen is new")
    func unseenUnaliasedIsNew() {
        let new = UnassignedPartition.newSinceSeen(entries: [entry(Self.loose)],
                                                   knownUUIDs: [], seen: [])
        #expect(new == [Self.loose])
    }

    @Test("An entry already seen is no longer new")
    func seenIsNotNew() {
        let new = UnassignedPartition.newSinceSeen(entries: [entry(Self.loose)],
                                                   knownUUIDs: [], seen: [Self.loose])
        #expect(new.isEmpty)
    }

    /// The case the plan names as most likely to ship wrong. The list keeps this parent so
    /// its child can nest; the badge must leave it alone, because somebody aliased it.
    @Test("An aliased grouped parent is listed but never counts as new")
    func aliasedParentIsListedButNotNew() {
        let entries = [entry(Self.parent), entry(Self.childA, parentID: Self.parent)]
        let knownUUIDs: Set<String> = [Self.parent]

        let listed = UnassignedPartition.listed(entries: entries, knownUUIDs: knownUUIDs)
        #expect(listed.contains { $0.point.id == Self.parent })

        let new = UnassignedPartition.newSinceSeen(entries: entries,
                                                   knownUUIDs: knownUUIDs, seen: [])
        #expect(new == [Self.childA])
    }

    @Test("Unaliased children each count once")
    func severalUnaliasedChildrenCount() {
        let entries = [entry(Self.parent),
                       entry(Self.childA, parentID: Self.parent),
                       entry(Self.childB, parentID: Self.parent)]
        let new = UnassignedPartition.newSinceSeen(entries: entries,
                                                   knownUUIDs: [Self.parent], seen: [])
        #expect(new == [Self.childA, Self.childB])
    }

    // MARK: - Visiting the pane

    @Test("A visit leaves nothing new behind")
    func visitClearsTheBadge() {
        let entries = [entry(Self.loose), entry(Self.childA)]
        let seen = UnassignedPartition.seenAfterVisit(entries: entries, knownUUIDs: [], seen: [])
        let new = UnassignedPartition.newSinceSeen(entries: entries, knownUUIDs: [],
                                                   seen: Set(seen))
        #expect(new.isEmpty)
    }

    @Test("A visit keeps identities it has already recorded")
    func visitKeepsEarlierIdentities() {
        let earlier = ["dddddddddddddddddddddddddddddddd"]
        let seen = UnassignedPartition.seenAfterVisit(entries: [entry(Self.loose)],
                                                      knownUUIDs: [], seen: earlier)
        #expect(Set(seen) == Set(earlier + [Self.loose]))
    }

    @Test("A visit records an identity once, however many times it is visited")
    func visitDoesNotDuplicate() {
        let once = UnassignedPartition.seenAfterVisit(entries: [entry(Self.loose)],
                                                      knownUUIDs: [], seen: [])
        let twice = UnassignedPartition.seenAfterVisit(entries: [entry(Self.loose)],
                                                       knownUUIDs: [], seen: once)
        #expect(twice == once)
    }

    /// An unaliased device that rotates its id adds one identity each time, and the set is
    /// stored, so it needs a ceiling. Oldest goes first: what a user has had longest is what
    /// they are least likely to be told about again.
    @Test("The seen set stops at its limit, dropping the oldest")
    func seenSetIsCapped() {
        let limit = UnassignedPartition.seenLimit
        let earlier = (0..<limit).map { String(format: "%032x", $0) }
        let seen = UnassignedPartition.seenAfterVisit(entries: [entry(Self.loose)],
                                                      knownUUIDs: [], seen: earlier)
        #expect(seen.count == limit)
        #expect(seen.contains(Self.loose))
        #expect(seen.contains(earlier[0]) == false)
        #expect(seen.contains(earlier[1]))
    }

    /// The badge agrees with the list. A rotated id on an unaliased device shows in the pane
    /// as a new row, so it raises the badge too — an earlier draft keyed the set on the
    /// device's name to avoid exactly this, and would have left the badge silent while the
    /// row sat there.
    @Test("A rotated id on an unaliased device is new, and is listed")
    func rotatedIdOnUnaliasedDeviceIsNew() {
        let rotated = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
        let entries = [entry(rotated)]
        let seen: Set<String> = [Self.loose]

        #expect(UnassignedPartition.listed(entries: entries, knownUUIDs: []).count == 1)
        #expect(UnassignedPartition.newSinceSeen(entries: entries, knownUUIDs: [], seen: seen)
                == [rotated])
    }
}
