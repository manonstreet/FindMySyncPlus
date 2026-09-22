import Foundation

// Grouped accessories: recognizing a group, nesting its children, and giving it a
// position. A group reaches here from one of two files — `Devices.data` may carry an
// embedded `itemGroup` on the parent's own record, `ItemGroups.data` describes the same
// group as a standalone record — and `groupParentRecords` reduces both to one shape.

extension SyncEngine {

    /// The cluster sizes in a group's `groupedItemIdentifiers`, or nil if it has none.
    /// Logged as a diagnostic only: Apple does split the array when pieces separate, but
    /// around twenty minutes late, and it stays split after they are back together — so the
    /// geometry decides separation and this is not consulted. Sizes only; the identifiers
    /// say nothing the log needs.
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
    /// Two positions disagree when they are further apart than the sum of their accuracy
    /// radii — their error circles do not overlap — which scales on its own when Apple's
    /// accuracy is poor. Only positions inside one `syncInterval` of each other are
    /// compared: fixes taken hours apart say nothing about where the pieces are now.
    /// Compared child to child, not against the group's own coordinate, which the status
    /// itself decides. Deliberately not `isOld`: that flag reads `false` on positions hours
    /// old for some position types, so comparability is stated on the pair directly.
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
                if Self.metersBetween(a.point, b.point) > a.point.accuracy + b.point.accuracy {
                    return "separated"
                }
            }
        }
        return compared ? "together" : "unknown"
    }

    /// Which child's position the group should take. Together, "freshest" cannot be wrong —
    /// every piece describes the same place. Separated, freshest picks arbitrarily between
    /// different places and swings the entity between `home` and `not_home`, so the group
    /// anchors to the case. `name` is AirPods vocabulary, hence the fallback.
    nonisolated func anchorChild(among children: [DevicePoint],
                                 freshest: DevicePoint,
                                 syncInterval: TimeInterval?) -> DevicePoint {
        guard let syncInterval,
              separationStatus(children: children, syncInterval: syncInterval) == "separated"
        else { return freshest }
        return children.first { $0.name == "Case" } ?? freshest
    }

    /// Great-circle distance in meters. Haversine, which is accurate well below the scale
    /// anything here cares about.
    nonisolated static func metersBetween(_ a: DevicePoint, _ b: DevicePoint) -> Double {
        let earthRadius = 6_371_000.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + sin(dLon / 2) * sin(dLon / 2) * cos(lat1) * cos(lat2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// What `backfillParentLocations` produced, and what it could not. The unresolved list
    /// exists because dropping a grouped child silently is how a run where every group keeps a
    /// wrong position looks completely normal. Pure, so it reports; the caller logs.
    struct BackfillResult {
        let points: [DevicePoint]
        let unresolvedChildren: [(id: String, groupIdentifier: String)]
    }

    /// Adapts `ItemGroups.data` records into the shape a device record with an `itemGroup`
    /// already has, so the parent-handling functions serve both sources unchanged. Apple
    /// writes the group record; only two of its keys are needed, and its id is the same id a
    /// device record carries on a machine that describes the group the other way.
    ///
    /// Two guards: an empty group must never become an entity (records with no members
    /// exist), and dedup by id, since a group described both ways is one group.
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

    /// Maps each grouped child's `groupIdentifier` to the parent device's id. A parent is a
    /// record carrying an `itemGroup` dict, keyed by its `baUUID`; the child's
    /// `groupIdentifier` carries the same string, so key and value are identical.
    func buildGroupParentIDs(rawDevices: [[String: Any]]) -> [String: String] {
        var map: [String: String] = [:]
        for raw in rawDevices {
            guard raw["itemGroup"] is [String: Any] else { continue }
            guard let parentID = (raw["baUUID"] as? String).nonNullish else { continue }
            map[parentID] = parentID
        }
        return map
    }

    /// Returns `points` with unaliased grouped children removed. A child is any point with a
    /// `parentID`; it stays when `aliasByUUID` has an entry for its normalized id. The group
    /// entity is the canonical one for the pair — users opt pieces in by aliasing them.
    nonisolated func filterUnaliasedGroupedChildren(
        _ points: [DevicePoint],
        aliasByUUID: [String: String]
    ) -> [DevicePoint] {
        return points.filter { p in
            guard p.parentID != nil else { return true }
            return aliasByUUID[p.id.normalized()] != nil
        }
    }

    /// Group parents that produced no point of their own, rebuilt from their anchor child.
    /// A parent can carry `$null` on both `location` and `crowdSourcedLocation`, so it never
    /// survives `parseDeviceArray` and would take its whole group with it — children nest
    /// under a row that has to exist. The child's rich attributes travel with the position,
    /// because they describe it accurately.
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

    struct Collision {
        let entity: String
        let kept: DevicePoint
        let dropped: [DevicePoint]
    }

    struct DedupeResult {
        let points: [DevicePoint]
        let collisions: [Collision]
    }

    /// One record per entity. Accessory records without a `baUUID` fall through to
    /// `deviceDiscoveryId`, a Bluetooth MAC, so two records for one physical accessory can
    /// share an id and both publish to the same entity in one run — Home Assistant shows one
    /// and the other overwrites it a moment later. The primary user's copy is the right one,
    /// and Apple marks it: `prsId` is the literal `"owner"` on this account's records and a
    /// DSID on a family member's. A family member's accessory can appear several times with
    /// no `owner` among the candidates, which is why the fall-through matters.
    nonisolated static func dedupeByEntity(_ points: [DevicePoint]) -> DedupeResult {
        // Indices, not the points themselves: the colliding records carry the *same* id,
        // which is what made them collide, so nothing about their contents identifies one.
        var indicesByEntity: [String: [Int]] = [:]
        for (index, point) in points.enumerated() {
            indicesByEntity[point.id.normalized(), default: []].append(index)
        }
        guard indicesByEntity.contains(where: { $0.value.count > 1 }) else {
            return DedupeResult(points: points, collisions: [])
        }

        var keep: Set<Int> = []
        var collisions: [Collision] = []
        for (entity, indices) in indicesByEntity {
            let winner = preferredIndex(among: indices, in: points)
            keep.insert(winner)
            guard indices.count > 1 else { continue }
            collisions.append(Collision(
                entity: entity,
                kept: points[winner],
                dropped: indices.filter { $0 != winner }.map { points[$0] }))
        }

        // Rebuilt in the original order rather than dictionary order, so the posted list
        // is stable for reasons beyond the tie-break.
        return DedupeResult(
            points: points.enumerated().filter { keep.contains($0.offset) }.map(\.element),
            collisions: collisions.sorted { $0.entity < $1.entity })
    }

    /// `owner` first, then the newest position, then the lowest `prsId`. The last step is
    /// there because the choice must not vary between runs; the identifier is identical across
    /// candidates by definition, and `prsId` differs because the records belong to different
    /// people. Position in the cache decides only if even that ties.
    nonisolated static func preferredIndex(among indices: [Int], in points: [DevicePoint]) -> Int {
        let owned = indices.filter { points[$0].prsId == "owner" }
        let pool = owned.isEmpty ? indices : owned
        return pool.sorted { lhs, rhs in
            let a = points[lhs], b = points[rhs]
            let ta = a.richAttributes?.timestamp ?? .distantPast
            let tb = b.richAttributes?.timestamp ?? .distantPast
            if ta != tb { return ta > tb }
            let pa = a.prsId ?? "", pb = b.prsId ?? ""
            if pa != pb { return pa < pb }
            return lhs < rhs
        }[0]
    }

    struct ChildIndex {
        let byParent: [String: [DevicePoint]]
        let freshestByParent: [String: (ts: Double, point: DevicePoint)]
        let unresolved: [(id: String, groupIdentifier: String)]
    }

    /// Children arranged the two ways the backfill needs them: all of a parent's pieces, for
    /// the anchor decision, and the freshest one, for the position itself. Also collects
    /// children that no parsed point matches — the group then sees no children and keeps a
    /// stale position — so they are returned rather than dropped silently.
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

    /// Gives each group parent its position: its own when current, else its anchor child's.
    /// Stale means `isOld`, or a child newer by a minute. Parents with no point at all are
    /// revived from their children first.
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
