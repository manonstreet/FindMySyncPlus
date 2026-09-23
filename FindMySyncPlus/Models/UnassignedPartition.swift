import Foundation

/// The Unassigned split, read by the Tracking pane's list and by the sidebar's new-entity
/// badge.
///
/// It lives here rather than on `TrackingView` because the sidebar cannot reach a private
/// computed property on a pane, and a second implementation of "unassigned" would let the
/// badge and the list tell different stories about the same entries.
///
/// The two answers differ, deliberately. `listed` keeps an *aliased* grouped parent visible
/// while one of its children is unaliased, so the child has a row to nest under.
/// `newSinceSeen` leaves that parent alone, because somebody aliased it and the badge exists
/// to point at what nobody has decided about.
///
/// Identity is `point.id.normalized()` throughout — what the alias map is keyed by and what
/// `RecordIdentityTests` pins. There is one identity model in this app.
///
/// Pure, so the cases are testable away from the view — see `UnassignedPartitionTests`.
enum UnassignedPartition {

    /// How many identities the seen set keeps.
    ///
    /// Apple rotates the ids of AirTags, iPhones and Watches, and an unaliased device adds
    /// one identity per rotation, so a stored set needs a ceiling. Pruning to what the cache
    /// currently holds was the other option and is worse: a device switched off for a day
    /// would leave the set and raise the badge again on its return, which is a false alarm
    /// the ceiling never produces. A real setup holds tens of identities, so this is reached
    /// by rotation alone.
    static let seenLimit = 1000

    /// Groups that some unaliased entry names as its parent, and so still have work under
    /// them.
    private static func groupedParentIDs(entries: [LocatedEntry],
                                         knownUUIDs: Set<String>) -> Set<String> {
        Set(entries
            .filter { !knownUUIDs.contains($0.point.id.normalized()) }
            .compactMap { $0.point.parentID?.normalized() })
    }

    /// The rows the Unassigned list shows: everything nobody has aliased, plus an aliased
    /// grouped parent while a child of its own is unaliased. Once every child is aliased the
    /// parent leaves, because nothing is left to manage there.
    static func listed(entries: [LocatedEntry], knownUUIDs: Set<String>) -> [LocatedEntry] {
        let parents = groupedParentIDs(entries: entries, knownUUIDs: knownUUIDs)
        return entries.filter { entry in
            let id = entry.point.id.normalized()
            guard knownUUIDs.contains(id) else { return true }
            return parents.contains(id)
        }
    }

    /// The identities the badge counts: unaliased, and absent from `seen`.
    ///
    /// Narrower than `listed`, which is the point of keeping both here.
    static func newSinceSeen(entries: [LocatedEntry], knownUUIDs: Set<String>,
                             seen: Set<String>) -> Set<String> {
        Set(entries.map { $0.point.id.normalized() })
            .subtracting(knownUUIDs)
            .subtracting(seen)
    }

    /// The top-level rows the collapsed list shows: an entry whose parent is absent stands on
    /// its own, and a group is one row with its children folded under it.
    ///
    /// The pane's own rule, so the two cannot disagree. A child whose parent is missing from
    /// the list is an orphan and shows flat, which is why the test is the parent's presence
    /// rather than whether a `parentID` exists at all.
    static func topLevelRows(entries: [LocatedEntry], knownUUIDs: Set<String>) -> [LocatedEntry] {
        let shown = listed(entries: entries, knownUUIDs: knownUUIDs)
        let shownIDs = Set(shown.map { $0.point.id.normalized() })
        return shown.filter { entry in
            guard let parent = entry.point.parentID?.normalized() else { return true }
            return !shownIDs.contains(parent)
        }
    }

    /// What the badge shows: the rows the collapsed pane would draw that carry something
    /// nobody has been shown yet.
    ///
    /// Rows rather than identities, because the pane opens collapsed and folds a group's
    /// children under it — counting identities put nine on the badge beside seven visible
    /// rows. It also drops the case the posting filter already settles: an unaliased grouped
    /// child is not published on its own, so aliasing one is not work the badge should point
    /// at. The group's row is.
    ///
    /// A row counts when it is itself unaliased and unseen, or when it is an aliased parent
    /// still holding an unseen child — the replacement bud that pairs into a group whose
    /// parent and siblings are already aliased.
    static func newRowsSinceSeen(entries: [LocatedEntry], knownUUIDs: Set<String>,
                                 seen: Set<String>) -> Int {
        let new = newSinceSeen(entries: entries, knownUUIDs: knownUUIDs, seen: seen)
        guard !new.isEmpty else { return 0 }

        let rows = topLevelRows(entries: entries, knownUUIDs: knownUUIDs)
        let rowIDs = Set(rows.map { $0.point.id.normalized() })
        // Which rows a new identity belongs to: itself when it stands at the top level, and
        // otherwise the row it folds under.
        var carrying: Set<String> = []
        for entry in entries {
            let id = entry.point.id.normalized()
            guard new.contains(id) else { continue }
            if rowIDs.contains(id) {
                carrying.insert(id)
            } else if let parent = entry.point.parentID?.normalized(), rowIDs.contains(parent) {
                carrying.insert(parent)
            }
        }
        return carrying.count
    }

    /// The seen set after the user opens Tracking, which is what clears the badge — the model
    /// an unread count already teaches.
    ///
    /// Ordered, and appended to in id order so a run produces the same list twice. The
    /// oldest go first at the ceiling: what someone has had longest is what they are least
    /// likely to want told about again.
    static func seenAfterVisit(entries: [LocatedEntry], knownUUIDs: Set<String>,
                               seen: [String]) -> [String] {
        var out = seen
        var present = Set(seen)
        for id in entries.map({ $0.point.id.normalized() }).sorted()
        where !knownUUIDs.contains(id) && present.insert(id).inserted {
            out.append(id)
        }
        if out.count > seenLimit { out.removeFirst(out.count - seenLimit) }
        return out
    }
}
