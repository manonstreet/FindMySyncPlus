import Foundation

// Grouped accessories: recognizing a group, nesting its children, and giving it a
// position. Split out of `SyncEngine.swift` when that file crossed SwiftLint's
// 1000-line limit, following the split `SyncEngineDiagnostics.swift` already made.
//
// A group reaches here from one of two files. `Devices.data` may carry an embedded
// `itemGroup` on the parent's own record; `ItemGroups.data` describes the same group
// as a standalone record. Both are reduced to one shape by `groupParentRecords`, so
// everything below sees a single kind of parent regardless of how Apple wrote it.

extension SyncEngine {

    /// The cluster sizes in a group's `groupedItemIdentifiers`, or nil if it has none.
    ///
    /// **Provisional, and here to answer one question.** The field measured as an array of
    /// arrays holding a single cluster of every piece while they were together — the shape
    /// you would expect if it meant "these are with each other". Whether Apple splits it
    /// when a piece is genuinely separated has never been observed, because everything
    /// available here lives in one case.
    ///
    /// If it does split, the flag beats inferring separation from how far apart the
    /// coordinates are. **If it does not, there is nothing worth logging and this comes
    /// out** — committed as provisional on issue #24 for exactly that reason.
    ///
    /// Sizes only. The identifiers themselves say nothing this question needs.
    nonisolated static func clusterSizes(_ group: [String: Any]) -> [Int]? {
        guard let raw = group["groupedItemIdentifiers"] as? [Any], !raw.isEmpty else { return nil }
        if raw.allSatisfy({ $0 is [Any] }) {
            return raw.compactMap { ($0 as? [Any])?.count }
        }
        // Flat, on a machine that writes it that way: one cluster of everything.
        return [raw.count]
    }

    /// Are the pieces of a group in the same place?
    ///
    /// **Distance is geometry, not a tuned constant.** Two positions disagree when they are
    /// further apart than the sum of their accuracy radii — their error circles do not
    /// overlap, so no single point satisfies both. That scales on its own when Apple's
    /// accuracy is poor, where a fixed metre threshold would not.
    ///
    /// Measured margin is wide: pieces in one case sit 5–6 m apart with 24–30 m accuracy
    /// each, roughly 5 m against a 54 m sum.
    ///
    /// **Two positions are only comparable if they describe the same moment.** Fixes taken
    /// hours apart say nothing about where the pieces are relative to each other now,
    /// however accurate each one is. `syncInterval` is the window the app itself treats as
    /// one observation, so positions inside it came from the same refresh and positions
    /// outside it did not.
    ///
    /// **This deliberately does not consult `isOld`.** That flag was the original guard,
    /// and issue #28 showed it reading `false` on a position nearly three hours old with
    /// `positionType: lastConnected` — so it does not mean "recent" for every position
    /// type. Comparability is a property of the *pair* and can be stated directly, which
    /// removes the dependency on a flag whose meaning varies.
    /// Are the pieces of a group in the same place?
    ///
    /// Compared **child to child**, not against the group's own coordinate. Whether the
    /// pieces are apart is a property of the pieces; comparing against the group would
    /// make this depend on a position that, once the status picks the anchor, depends on
    /// this. It also removes a false positive: a parent holding a stale position of its
    /// own reads as separated from its own children, masked today only because the
    /// backfill happens to revive it first.
    ///
    /// Positions taken too far apart in time are not compared — a piece that reported
    /// yesterday is not evidence of where it is now.
    nonisolated func separationStatus(children: [DevicePoint],
                                      syncInterval: TimeInterval) -> String {
        let dated = children.compactMap { child -> (point: DevicePoint, at: Date)? in
            guard let at = child.richAttributes?.timestamp else { return nil }
            return (child, at)
        }
        guard dated.count >= 2 else { return "unknown" }

        var compared = false
        for i in dated.indices {
            for j in dated.index(after: i)..<dated.endIndex {
                let a = dated[i], b = dated[j]
                guard abs(a.at.timeIntervalSince(b.at)) <= syncInterval else { continue }
                compared = true
                if Self.metresBetween(a.point, b.point) > a.point.accuracy + b.point.accuracy {
                    return "separated"
                }
            }
        }
        return compared ? "together" : "unknown"
    }

    /// Which child's position the group should take.
    ///
    /// While the pieces are together, "freshest" is a recency choice among positions that
    /// all describe the same place, so it cannot be wrong. While they are apart it is the
    /// one rule guaranteed to pick arbitrarily between different places — measured on a
    /// live cache, the freshest child flipped five times in seventeen runs between points
    /// 766 m apart, which on this path swings the entity between `home` and `not_home`.
    ///
    /// So while separated, anchor to the case. `name` is AirPods vocabulary and we have
    /// measured one product's values for it, hence the fallback rather than a guarantee.
    nonisolated func anchorChild(among children: [DevicePoint],
                                 freshest: DevicePoint,
                                 syncInterval: TimeInterval?) -> DevicePoint {
        guard let syncInterval,
              separationStatus(children: children, syncInterval: syncInterval) == "separated"
        else { return freshest }
        return children.first { $0.name == "Case" } ?? freshest
    }

    /// Great-circle distance in metres. Haversine, which is accurate well below the scale
    /// anything here cares about.
    nonisolated static func metresBetween(_ a: DevicePoint, _ b: DevicePoint) -> Double {
        let earthRadius = 6_371_000.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + sin(dLon / 2) * sin(dLon / 2) * cos(lat1) * cos(lat2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// What `backfillParentLocations` produced, and what it could not.
    ///
    /// The unresolved list exists because dropping a grouped child silently is how a run
    /// where every group keeps a wrong position looks completely normal. The function is
    /// `nonisolated` and pure, so it reports rather than logs — the caller does that.
    struct BackfillResult {
        let points: [DevicePoint]
        let unresolvedChildren: [(id: String, groupIdentifier: String)]
    }

    /// Adapts `ItemGroups.data` records into the shape a device record that owns an
    /// `itemGroup` already has, so `buildGroupParentIDs`, `revivedParents` and
    /// `backfillParentLocations` handle both sources with no changes of their own.
    ///
    /// This is not synthesizing a parent — the framing that got this deferred and was
    /// wrong about its own subject. Apple writes the group record; only two of its ten
    /// keys are needed, and the id it carries is the *same id* a device record would
    /// have carried on a machine that described the group the other way.
    ///
    /// Two guards, both from measurement rather than caution:
    ///
    /// - **An empty group must never become an entity.** mini carries a second record
    ///   with no members at all.
    /// - **Dedup by id.** If one machine ever describes a group both ways it is still
    ///   one group. Keying on the id does this without name matching, which would be a
    ///   guess.
    nonisolated func groupParentRecords(
        fromItemGroups rawGroups: [[String: Any]],
        existingParentIDs: Set<String>
    ) -> [[String: Any]] {
        var adapted: [[String: Any]] = []
        var seen = existingParentIDs
        for group in rawGroups {
            guard let id = (group["identifier"] as? String).nonNullish else { continue }
            guard !seen.contains(id) else { continue }
            // `itemIdentifiers` is every physical piece. Empty means there is nothing to
            // position the group from and nothing for it to represent.
            guard let members = group["itemIdentifiers"] as? [Any], !members.isEmpty else { continue }
            seen.insert(id)
            adapted.append([
                "baUUID": id,
                "name": (group["name"] as? String).nonNullish ?? "",
                // The predicate every parent-handling function tests. The group record
                // is its own group dictionary — same ten keys either way.
                "itemGroup": group
            ])
        }
        return adapted
    }

    /// Maps each grouped child's `groupIdentifier` to the parent device's id.
    /// A parent device entry in Devices.data is identified by the presence of
    /// an `itemGroup` dict; the parent's id is its `baUUID`. The child's
    /// `groupIdentifier` field carries the same string, so the map's key and
    /// value are identical.
    func buildGroupParentIDs(rawDevices: [[String: Any]]) -> [String: String] {
        var map: [String: String] = [:]
        for raw in rawDevices {
            guard raw["itemGroup"] is [String: Any] else { continue }
            guard let parentID = (raw["baUUID"] as? String).nonNullish else { continue }
            map[parentID] = parentID
        }
        return map
    }

    /// Returns `points` with unaliased grouped children removed. A "child" is
    /// any DevicePoint with a non-nil `parentID`; "aliased" means an entry in
    /// `aliasByUUID` exists for the child's id (normalized). Aliased children
    /// are always preserved so existing user setups continue to publish
    /// unchanged. Unaliased children are dropped because the parent group
    /// entity (e.g. "AirPods Pro") is the canonical entity for the pair —
    /// users opt sub-items in by aliasing them.
    nonisolated func filterUnaliasedGroupedChildren(
        _ points: [DevicePoint],
        aliasByUUID: [String: String]
    ) -> [DevicePoint] {
        return points.filter { p in
            guard p.parentID != nil else { return true }
            return aliasByUUID[p.id.normalized()] != nil
        }
    }

    /// Returns `parents` with each parent's location replaced by its freshest
    /// child's location when the parent's own location is unreliable. A
    /// parent location is considered unreliable when its `isOld` flag is true
    /// or when at least one child reports a `timeStamp` newer by ≥ 60_000 ms.
    /// Group parents that produced no point of their own, rebuilt from their freshest
    /// child.
    ///
    /// A parent can carry `$null` on both `location` and `crowdSourcedLocation`, so it
    /// never survives `parseDeviceArray` and would otherwise never appear — taking its
    /// whole group with it, since children nest under a row that has to exist.
    ///
    /// Its record is real; only the position is missing, and the freshest child is
    /// already the answer given to every other parent. The child's rich attributes
    /// travel with it, because the position *is* the child's and its timestamp and
    /// staleness describe it accurately.
    nonisolated private func revivedParents(
        rawDevices: [[String: Any]],
        alreadyParsed: Set<String>,
        freshestChildByParent: [String: (ts: Double, point: DevicePoint)],
        childrenByParent: [String: [DevicePoint]],
        syncInterval: TimeInterval?
    ) -> [DevicePoint] {
        var revived: [DevicePoint] = []
        for raw in rawDevices {
            guard raw["itemGroup"] is [String: Any] else { continue }
            guard let id = (raw["baUUID"] as? String).nonNullish, !alreadyParsed.contains(id) else { continue }
            // No reporting child means nothing to give it, and inventing a position
            // would be worse than showing none.
            guard let (_, freshest) = freshestChildByParent[id] else { continue }
            let child = anchorChild(among: childrenByParent[id] ?? [],
                                    freshest: freshest,
                                    syncInterval: syncInterval)
            revived.append(DevicePoint(
                id: id,
                name: (raw["name"] as? String) ?? "",
                latitude: child.latitude,
                longitude: child.longitude,
                accuracy: child.accuracy,
                battery: nil,
                // The position is this child's, so say so rather than leaving a
                // coordinate that reads as a measurement of the group.
                richAttributes: child.richAttributes?.namingSource(child.name)
            ))
        }
        return revived
    }

    struct ChildIndex {
        let byParent: [String: [DevicePoint]]
        let freshestByParent: [String: (ts: Double, point: DevicePoint)]
        let unresolved: [(id: String, groupIdentifier: String)]
    }

    /// Children arranged the two ways the backfill needs them: all of a parent's pieces,
    /// for the anchor decision, and the freshest one, for the position itself.
    ///
    /// Also collects children that no parsed point matches. That is the failure mode
    /// behind issue #24 — the group then sees no children and keeps its own stale
    /// position — so it is returned rather than dropped silently.
    nonisolated private func indexChildren(
        children: [DevicePoint],
        rawItems: [[String: Any]]
    ) -> ChildIndex {

        let childByID: [String: DevicePoint] = Dictionary(
            uniqueKeysWithValues: children.compactMap { c -> (String, DevicePoint)? in
                guard c.parentID != nil else { return nil }
                return (c.id, c)
            }
        )
        var byParent: [String: [DevicePoint]] = [:]
        for child in children {
            guard let pid = child.parentID else { continue }
            byParent[pid, default: []].append(child)
        }

        var freshestByParent: [String: (ts: Double, point: DevicePoint)] = [:]
        var unresolved: [(id: String, groupIdentifier: String)] = []
        for raw in rawItems {
            guard let id = CacheDecryptor.resolveID(raw) else { continue }
            guard let point = childByID[id], let pid = point.parentID else {
                if let gid = (raw["groupIdentifier"] as? String).nonNullish {
                    unresolved.append((id: id, groupIdentifier: gid))
                }
                continue
            }
            let ts = ((raw["location"] as? [String: Any])?["timeStamp"] as? Double) ?? 0
            if let existing = freshestByParent[pid], ts <= existing.ts { continue }
            freshestByParent[pid] = (ts, point)
        }
        return ChildIndex(byParent: byParent,
                          freshestByParent: freshestByParent,
                          unresolved: unresolved)
    }

    nonisolated func backfillParentLocations(
        parents: [DevicePoint],
        children: [DevicePoint],
        rawDevices: [[String: Any]],
        rawItems: [[String: Any]],
        syncInterval: TimeInterval? = nil
    ) -> BackfillResult {
        var unresolvedChildren: [(id: String, groupIdentifier: String)] = []
        // Deliberately not `guard !parents.isEmpty`: a parent whose position is absent
        // rather than stale never parsed, so it arrives here as nothing at all. That is
        // the case this has to handle, and returning early would skip it.
        struct Stamp { let ts: Double; let isOld: Bool }
        var parentStamp: [String: Stamp] = [:]
        for raw in rawDevices {
            guard raw["itemGroup"] is [String: Any] else { continue }
            guard let id = (raw["baUUID"] as? String).nonNullish else { continue }
            let loc = raw["location"] as? [String: Any]
            let ts = (loc?["timeStamp"] as? Double) ?? 0
            let isOld = (loc?["isOld"] as? Bool) ?? false
            parentStamp[id] = Stamp(ts: ts, isOld: isOld)
        }

        let indexed = indexChildren(children: children, rawItems: rawItems)
        let childrenByParent = indexed.byParent
        let freshestChildByParent = indexed.freshestByParent
        unresolvedChildren = indexed.unresolved

        let staleThresholdMs: Double = 60_000

        // A parent with no position of its own produced no point, so it is not in
        // `parents`. See `revivedParents` for why it has to be rebuilt here.
        let revived = revivedParents(rawDevices: rawDevices,
                                     alreadyParsed: Set(parents.map(\.id)),
                                     freshestChildByParent: freshestChildByParent,
                                     childrenByParent: childrenByParent,
                                     syncInterval: syncInterval)

        let points = revived + parents.map { parent in
            guard let pst = parentStamp[parent.id],
                  let (childTs, freshestPoint) = freshestChildByParent[parent.id] else {
                return parent.withRichAttributes(
                    (parent.richAttributes ?? .empty).namingSource("self"))
            }
            let childPoint = anchorChild(among: childrenByParent[parent.id] ?? [],
                                         freshest: freshestPoint,
                                         syncInterval: syncInterval)
            let parentIsStale = pst.isOld || (childTs > pst.ts + staleThresholdMs)
            guard parentIsStale else {
                return parent.withRichAttributes(
                    (parent.richAttributes ?? .empty).namingSource("self"))
            }
            return DevicePoint(
                id: parent.id,
                name: parent.name,
                latitude: childPoint.latitude,
                longitude: childPoint.longitude,
                accuracy: childPoint.accuracy,
                battery: parent.battery,
                prsId: parent.prsId,
                richAttributes: childPoint.richAttributes?.namingSource(childPoint.name),
                parentID: parent.parentID
            )
        }
        return BackfillResult(points: points, unresolvedChildren: unresolvedChildren)
    }
}
