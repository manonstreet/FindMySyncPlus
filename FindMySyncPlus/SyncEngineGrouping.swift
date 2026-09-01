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
        freshestChildByParent: [String: (ts: Double, point: DevicePoint)]
    ) -> [DevicePoint] {
        var revived: [DevicePoint] = []
        for raw in rawDevices {
            guard raw["itemGroup"] is [String: Any] else { continue }
            guard let id = (raw["baUUID"] as? String).nonNullish, !alreadyParsed.contains(id) else { continue }
            // No reporting child means nothing to give it, and inventing a position
            // would be worse than showing none.
            guard let (_, child) = freshestChildByParent[id] else { continue }
            revived.append(DevicePoint(
                id: id,
                name: (raw["name"] as? String) ?? "",
                latitude: child.latitude,
                longitude: child.longitude,
                accuracy: child.accuracy,
                battery: nil,
                richAttributes: child.richAttributes
            ))
        }
        return revived
    }

    nonisolated func backfillParentLocations(
        parents: [DevicePoint],
        children: [DevicePoint],
        rawDevices: [[String: Any]],
        rawItems: [[String: Any]]
    ) -> [DevicePoint] {
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

        // Map parentID -> freshest child (id, timestamp, point).
        let childByID: [String: DevicePoint] = Dictionary(
            uniqueKeysWithValues: children.compactMap { c -> (String, DevicePoint)? in
                guard c.parentID != nil else { return nil }
                return (c.id, c)
            }
        )
        var freshestChildByParent: [String: (ts: Double, point: DevicePoint)] = [:]
        for raw in rawItems {
            let id = (raw["identifier"] as? String).nonNullish
                ?? (raw["baUUID"] as? String).nonNullish
                ?? (raw["deviceDiscoveryId"] as? String).nonNullish
                ?? (raw["serialNumber"] as? String).nonNullish
            guard let id else { continue }
            guard let point = childByID[id], let pid = point.parentID else { continue }
            let loc = raw["location"] as? [String: Any]
            let ts = (loc?["timeStamp"] as? Double) ?? 0
            if let existing = freshestChildByParent[pid] {
                if ts > existing.ts {
                    freshestChildByParent[pid] = (ts, point)
                }
            } else {
                freshestChildByParent[pid] = (ts, point)
            }
        }

        let staleThresholdMs: Double = 60_000

        // A parent with no position of its own produced no point, so it is not in
        // `parents`. See `revivedParents` for why it has to be rebuilt here.
        let revived = revivedParents(rawDevices: rawDevices,
                                     alreadyParsed: Set(parents.map(\.id)),
                                     freshestChildByParent: freshestChildByParent)

        return revived + parents.map { parent in
            guard let pst = parentStamp[parent.id],
                  let (childTs, childPoint) = freshestChildByParent[parent.id] else {
                return parent
            }
            let parentIsStale = pst.isOld || (childTs > pst.ts + staleThresholdMs)
            guard parentIsStale else { return parent }
            return DevicePoint(
                id: parent.id,
                name: parent.name,
                latitude: childPoint.latitude,
                longitude: childPoint.longitude,
                accuracy: childPoint.accuracy,
                battery: parent.battery,
                prsId: parent.prsId,
                richAttributes: parent.richAttributes,
                parentID: parent.parentID
            )
        }
    }
}
