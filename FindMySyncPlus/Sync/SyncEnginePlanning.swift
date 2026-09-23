import Foundation

// MARK: - Build the plan

extension SyncEngine {

    /// What one run will post, keyed for the transport, plus the counts the run line reports.
    struct PlanPhase {
        let toPost: [DevicePoint]
        let aliasByUUID: [String: String]
        let metrics: RunMetrics

        static var empty: PlanPhase {
            PlanPhase(toPost: [], aliasByUUID: [:], metrics: RunMetrics(
                discoveredDevices: 0, discoveredItems: 0, discoveredFriends: 0,
                locatedDevices: 0, locatedItems: 0, locatedFriends: 0,
                unassignedCount: 0, notTrackedCount: 0, toPostCount: 0, noLocationCount: 0))
        }
    }

    /// Everything the device and friend passes accumulate, flushed once at the end.
    private struct PlanAccumulator {
        var toPost: [DevicePoint] = []
        var aliasByUUID: [String: String] = [:]
        var unassignedCount = 0
        var notTrackedCount = 0
        var lastSeenNameUpdates: [(aliasKey: String, name: String)] = []
        var parentAliasUpdates: [(aliasKey: String, parentAlias: String)] = []
        var parentGroupUpdates: [SettingsStore.ParentGroupUpdate] = []

        /// A record with an alias: post it if tracked, count it otherwise.
        mutating func admit(_ point: DevicePoint, key: String, alias rec: DeviceAlias) {
            if rec.tracked {
                toPost.append(point)
                aliasByUUID[key] = rec.alias
            } else {
                notTrackedCount += 1
            }
        }
    }

    /// The per-plan facts every step reads and none of them change.
    private struct PlanContext {
        let settings: SettingsStore
        let logger: LogStore
        let app: AppModel
        let allowAutoLearn: Bool
        let sourceMap: [String: DeviceSource]
        /// The DSIDs of every family member with a device in the FMIP caches.
        let familyDSIDs: Set<String>
        /// Rich attributes from the LocalStorage friend records, by DSID, for the family merge.
        let friendRichByDSID: [String: RichLocationAttributes]
        /// Apple's name for each group, so a child can persist it beside the id and the
        /// Aliases list can label a header with nothing live to read.
        let groupNamesByID: [String: String]
    }

    /// Decide what to post from everything the read phase produced, log each record the way
    /// the Status window shows it, and persist what this run learned about aliases.
    func buildPlanAndLog(devicesBySource: [FMIPCacheFile: [DevicePoint]],
                         rawBySource: [FMIPCacheFile: [[String: Any]]],
                         friendEntries: [DevicePoint] = [],
                         settings: SettingsStore,
                         logger: LogStore,
                         allowAutoLearn: Bool) -> PlanPhase {
        guard let app else { return .empty }

        // UUID → alias record, once for this plan. Auto-learn adds to it as it goes.
        var aliasByUUIDLocal: [String: DeviceAlias] = [:]
        aliasByUUIDLocal.reserveCapacity(settings.aliases.count * 2)
        for a in settings.aliases {
            for u in a.knownUUIDs { aliasByUUIDLocal[u] = a }
        }

        var sourceMap = sourceByUUIDMap(from: devicesBySource)
        for f in friendEntries { sourceMap[f.id.normalized()] = .friend }

        let locatedIDs = Set(devicesBySource.values.joined().map { $0.id.normalized() })
        let noLocationCount = logLocationOutcomes(rawBySource: rawBySource,
                                                  locatedIDs: locatedIDs,
                                                  logger: logger)

        let allDevices = Array(devicesBySource.values.joined())
        let context = PlanContext(
            settings: settings, logger: logger, app: app, allowAutoLearn: allowAutoLearn,
            sourceMap: sourceMap,
            familyDSIDs: Self.familyDSIDs(in: devicesBySource),
            friendRichByDSID: Self.friendRichByDSID(friendEntries),
            groupNamesByID: Dictionary(allDevices.map { ($0.id.normalized(), $0.name) },
                                       uniquingKeysWith: { first, _ in first }))
        let familyDSIDs = context.familyDSIDs
        var acc = PlanAccumulator()

        planDevices(allDevices, context: context, aliasByUUIDLocal: &aliasByUUIDLocal, into: &acc)
        planFriends(friendEntries, context: context, aliasByUUIDLocal: aliasByUUIDLocal, into: &acc)

        // One storage write per kind, not one per device.
        settings.batchUpdateLastSeenNames(acc.lastSeenNameUpdates)
        settings.batchUpdateParentAliases(acc.parentAliasUpdates)
        settings.batchUpdateParentGroups(acc.parentGroupUpdates)

        // The UI list gains the non-family friends; family members are already there as
        // their devices.
        var allEntries = app.lastLocatedEntries
        for f in friendEntries where !familyDSIDs.contains(f.id.normalized()) {
            allEntries.append(LocatedEntry(point: f, source: .friend))
        }
        app.lastLocatedEntries = allEntries

        // The group entity is the canonical one for a pair; pieces publish only when the
        // user has aliased them.
        let filteredToPost = filterUnaliasedGroupedChildren(acc.toPost, aliasByUUID: acc.aliasByUUID)
        let droppedChildren = acc.toPost.count - filteredToPost.count
        if droppedChildren > 0 {
            logger.debug("Skipped \(droppedChildren) unaliased grouped child entr\(droppedChildren == 1 ? "y" : "ies") from posting.")
        }

        let deduped = Self.dedupeByEntity(filteredToPost)
        logCollisions(deduped.collisions, logger: logger)

        let metrics = RunMetrics(
            discoveredDevices: rawBySource[.devices]?.count ?? 0,
            discoveredItems: rawBySource[.items]?.count ?? 0,
            discoveredFriends: friendEntries.count,
            locatedDevices: devicesBySource[.devices]?.count ?? 0,
            locatedItems: devicesBySource[.items]?.count ?? 0,
            locatedFriends: friendEntries.count(where: { !familyDSIDs.contains($0.id.normalized()) }),
            unassignedCount: acc.unassignedCount,
            notTrackedCount: acc.notTrackedCount,
            toPostCount: deduped.points.count,
            noLocationCount: noLocationCount
        )

        // Home reads this, and so does the status entity's `unassigned`. Published here
        // rather than in the run summary so a dry run updates it too: a dry run reads and
        // decrypts everything, and the number it finds is as true as any other run's.
        app.unassignedCount = acc.unassignedCount

        return PlanPhase(toPost: deduped.points, aliasByUUID: acc.aliasByUUID, metrics: metrics)
    }

    // MARK: Steps

    /// One pass over the FMIP devices and items: merge a family member's friend record onto
    /// their device, resolve the alias — stored, or learned from a name match — and log.
    private func planDevices(_ devices: [DevicePoint],
                             context: PlanContext,
                             aliasByUUIDLocal: inout [String: DeviceAlias],
                             into acc: inout PlanAccumulator) {
        let logger = context.logger
        for var d in devices {
            // A family member's device appears in both caches. The friend record's richer
            // fields win where it has a value; ours fill the gaps.
            if let prs = d.prsId, prs != "owner",
               let friendRich = context.friendRichByDSID[prs.normalized()] {
                d = d.with(richAttributes: d.richAttributes?.mergedPreferring(friendRich) ?? friendRich)
            }
            let uuid = d.id.normalized()
            let srcLabel = Self.sourceLabel(for: context.sourceMap[uuid])

            if let rec = aliasByUUIDLocal[uuid] {
                if !d.name.isEmpty {
                    acc.lastSeenNameUpdates.append((aliasKey: rec.alias, name: d.name))
                }
                recordGroupMembership(of: d, alias: rec, context: context,
                                      aliasByUUIDLocal: aliasByUUIDLocal, into: &acc)
                logDevice(d, source: srcLabel, alias: rec.alias, tracked: rec.tracked, logger: logger)
                acc.admit(d, key: uuid, alias: rec)
            } else if context.allowAutoLearn,
                      let rec = autoLearnAlias(for: d, context: context,
                                               aliasByUUIDLocal: &aliasByUUIDLocal) {
                logDevice(d, source: srcLabel, alias: rec.alias, tracked: rec.tracked, logger: logger)
                acc.admit(d, key: uuid, alias: rec)
            } else {
                logDevice(d, source: srcLabel, alias: nil, tracked: false, logger: logger)
                acc.unassignedCount += 1
            }
        }
    }

    /// Persist the child's group on both aliases and by the group's own id, so the Aliases
    /// list can nest the pair whether or not either reported this cycle. Keyed on aliases
    /// because UUIDs rotate; the id and name are kept too, for a group the user never aliased.
    private func recordGroupMembership(of d: DevicePoint,
                                       alias rec: DeviceAlias,
                                       context: PlanContext,
                                       aliasByUUIDLocal: [String: DeviceAlias],
                                       into acc: inout PlanAccumulator) {
        guard let parentID = d.parentID else { return }
        if let parentRec = aliasByUUIDLocal[parentID.normalized()], parentRec.alias != rec.alias {
            acc.parentAliasUpdates.append((aliasKey: rec.alias, parentAlias: parentRec.alias))
        }
        let groupID = parentID.normalized()
        acc.parentGroupUpdates.append(.init(aliasKey: rec.alias,
                                            groupID: groupID,
                                            groupName: context.groupNamesByID[groupID] ?? "Group"))
    }

    /// Match an unaliased record to an alias by its last-seen name, and remember the new
    /// UUID under it. UUIDs rotate; names do not.
    private func autoLearnAlias(for d: DevicePoint,
                                context: PlanContext,
                                aliasByUUIDLocal: inout [String: DeviceAlias]) -> DeviceAlias? {
        let (settings, logger, app) = (context.settings, context.logger, context.app)
        guard !d.name.isEmpty,
              let matchIdx = settings.aliases.firstIndex(where: {
                  ($0.lastSeenName ?? "").caseInsensitiveCompare(d.name) == .orderedSame
              })
        else { return nil }
        let aliasKey = settings.aliases[matchIdx].alias
        let evicted = settings.updateAliasWithCap(aliasKey, addUUID: d.id, lastSeenName: d.name)
        guard let updated = settings.aliases.first(where: { $0.alias == aliasKey }) else { return nil }
        aliasByUUIDLocal[d.id.normalized()] = updated
        if !evicted.isEmpty {
            logger.debug("Alias \"\(aliasKey)\" reached cap; evicted \(evicted.count) old UUID(s)")
        }
        logger.info("Auto-learned UUID \(d.id.normalized()) for alias \"\(aliasKey)\" (name match)")
        app.learnedUUIDsCount &+= 1
        return updated
    }

    /// One pass over the friends. A family member is skipped: their devices are already
    /// tracked, matched on DSID.
    private func planFriends(_ friendEntries: [DevicePoint],
                             context: PlanContext,
                             aliasByUUIDLocal: [String: DeviceAlias],
                             into acc: inout PlanAccumulator) {
        let logger = context.logger
        for f in friendEntries {
            let friendID = f.id.normalized()

            if context.familyDSIDs.contains(friendID) {
                logger.debug("Friend \"\(f.name.isEmpty ? f.id : f.name)\" is a family member (DSID match) — skipping (devices already tracked)")
                continue
            }

            if let rec = aliasByUUIDLocal[friendID] {
                if !f.name.isEmpty {
                    acc.lastSeenNameUpdates.append((aliasKey: rec.alias, name: f.name))
                }
                logDevice(f, source: "Friend", alias: rec.alias, tracked: rec.tracked, logger: logger)
                acc.admit(f, key: friendID, alias: rec)
            } else {
                logDevice(f, source: "Friend", alias: nil, tracked: false, logger: logger)
                acc.unassignedCount += 1
            }
        }
    }

    // MARK: Lookups

    /// The DSIDs of every family member with a device in the FMIP caches.
    private static func familyDSIDs(in devicesBySource: [FMIPCacheFile: [DevicePoint]]) -> Set<String> {
        var dsids: Set<String> = []
        for devices in devicesBySource.values {
            for d in devices {
                if let prs = d.prsId, prs != "owner" {
                    dsids.insert(prs.normalized())
                }
            }
        }
        return dsids
    }

    /// Rich attributes from the LocalStorage friend records, by DSID, for the family merge.
    private static func friendRichByDSID(_ friendEntries: [DevicePoint]) -> [String: RichLocationAttributes] {
        var byDSID: [String: RichLocationAttributes] = [:]
        for f in friendEntries {
            if let rich = f.richAttributes {
                byDSID[f.id.normalized()] = rich
            }
        }
        return byDSID
    }

    private func sourceByUUIDMap(from devicesBySource: [FMIPCacheFile: [DevicePoint]]) -> [String: DeviceSource] {
        var map: [String: DeviceSource] = [:]
        for (file, list) in devicesBySource {
            let src: DeviceSource = (file == .devices) ? .device : .item
            for d in list { map[d.id.normalized()] = src }
        }
        return map
    }

    private static func sourceLabel(for src: DeviceSource?) -> String {
        switch src {
        case .item: return "Item"
        case .friend: return "Friend"
        case .group: return "Group"
        default: return "Device"
        }
    }

    // MARK: Logging

    private func logDevice(_ d: DevicePoint, source: String, alias: String?, tracked: Bool, logger: LogStore) {
        var header = "- \(source) \"\(d.name)\" - \(d.id)"
        if let alias {
            header += " (alias: \(alias))"
            if !tracked { header += " (not tracked)" }
        }
        let useInfo = (alias != nil && tracked)
        if useInfo {
            logger.info(header)
            logger.info("- - Location: \(d.latitude), \(d.longitude) (Accuracy \(d.accuracy))")
            if let b = d.battery { logger.info("- - Battery level: \(b)") }
        } else {
            logger.debug(header)
            logger.debug("- - Location: \(d.latitude), \(d.longitude) (Accuracy \(d.accuracy))")
            if let b = d.battery { logger.debug("- - Battery level: \(b)") }
        }
    }

    /// Says which record won a collision and which lost, because both are needed to tell
    /// whether the rule chose correctly. `.info` rather than `.warn`: Apple writes these
    /// duplicates, so there is nothing the user can act on, but a record is being dropped.
    private func logCollisions(_ collisions: [SyncEngine.Collision], logger: LogStore) {
        for collision in collisions {
            let dropped = collision.dropped.map { Self.collisionDescription($0) }
            // The record's own id, not the normalized key: every other device line prints
            // it as written, and two renderings of one id in one log is a puzzle.
            logger.info("Duplicate id \(collision.kept.id) — publishing " +
                        "\(Self.collisionDescription(collision.kept)), dropping " +
                        dropped.joined(separator: ", "))
        }
    }

    nonisolated static func collisionDescription(_ point: DevicePoint) -> String {
        let owner: String
        switch point.prsId {
        case "owner": owner = "owner"
        case .some: owner = "family"
        case nil: owner = "unowned"
        }
        var parts = [owner]
        if let type = point.richAttributes?.positionType { parts.append(type) }
        if let at = point.richAttributes?.timestamp {
            parts.append(ageDescription(Date().timeIntervalSince(at) / 3600))
        }
        return "\"\(point.name)\" (\(parts.joined(separator: ", ")))"
    }
}
