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
