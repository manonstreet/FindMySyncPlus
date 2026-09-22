import Foundation

// MARK: - Read and parse the caches

extension SyncEngine {

    /// One run's read of the FMIP caches: raw records per file, parsed points per file,
    /// and whether any cache decrypted at all.
    struct IOPhase {
        let rawBySource: [FMIPCacheFile: [[String: Any]]]
        let devicesBySource: [FMIPCacheFile: [DevicePoint]]
        let hadSuccessfulDecrypt: Bool
    }

    /// Read, decrypt and parse every enabled cache, then give grouped accessories their
    /// positions. Parsing waits until every file is read, because Items.data children need
    /// the parent ids that Devices.data and ItemGroups.data supply.
    func readAndParseCaches(candidates: [FMIPCacheFile],
                            settings: SettingsStore,
                            logger: LogStore) async throws -> IOPhase {
        guard let app else { throw DecryptorError.keyNotLoaded }

        let raw = try await readRawCaches(candidates: candidates, settings: settings, logger: logger)
        let groups = resolveGroupParents(rawBySource: raw.bySource, logger: logger)
        var devicesBySource = parseDevicePoints(rawBySource: raw.bySource,
                                                groupParentIDs: groups.parentIDMap)
        devicesBySource = applyGroupPositions(to: devicesBySource,
                                              rawBySource: raw.bySource,
                                              groups: groups,
                                              settings: settings,
                                              logger: logger)
        publishLocatedEntries(devicesBySource, to: app)

        return IOPhase(rawBySource: raw.bySource,
                       devicesBySource: devicesBySource,
                       hadSuccessfulDecrypt: raw.hadSuccessfulDecrypt)
    }

    // MARK: Steps

    private struct RawCaches {
        let bySource: [FMIPCacheFile: [[String: Any]]]
        let hadSuccessfulDecrypt: Bool
    }

    /// Read and decrypt each cache into raw records. A wrong key aborts the run; a missing
    /// file is nothing to report, since not every machine has every cache.
    private func readRawCaches(candidates: [FMIPCacheFile],
                               settings: SettingsStore,
                               logger: LogStore) async throws -> RawCaches {
        var bySource: [FMIPCacheFile: [[String: Any]]] = [:]
        var hadSuccessfulDecrypt = false

        for file in candidates {
            switch await cacheDecryptor.readEncryptedPayload(from: file, logger: logger) {
            case .success(let data):
                switch await cacheDecryptor.decryptPayload(data, logger: logger) {
                case .success(let plaintext):
                    switch cacheDecryptor.parsePlistData(plaintext) {
                    case .success(let arr):
                        bySource[file, default: []].append(contentsOf: arr)
                        hadSuccessfulDecrypt = true
                    case .failure(let e):
                        logger.warn("\(file.displayName) plist parse failed: \(e.localizedDescription)")
                    }
                case .failure(.incorrectKey):
                    settings.fmipKeyStatus = .invalid
                    throw DecryptorError.incorrectKey
                case .failure(let e):
                    logger.warn("\(file.displayName) decrypt failed: \(e.localizedDescription)")
                }
            case .failure(let e):
                if case .fileReadError(let underlying as NSError) = e,
                   underlying.domain == NSCocoaErrorDomain && underlying.code == NSFileReadNoSuchFileError {
                    // Absent, not broken.
                } else if case .fdaRequired = e {
                    throw DecryptorError.fdaRequired
                } else {
                    logger.warn("\(file.displayName) read failed: \(e.localizedDescription)")
                }
            }
        }
        return RawCaches(bySource: bySource, hadSuccessfulDecrypt: hadSuccessfulDecrypt)
    }

    private struct GroupParents {
        /// Every parent record from either file, reduced to one shape.
        let records: [[String: Any]]
        /// A child's `groupIdentifier` → its parent's id, for stamping `parentID` on items.
        let parentIDMap: [String: String]
        /// The ids of every parent, for picking parents out of the parsed devices.
        var parentIDs: Set<String> { Set(parentIDMap.keys) }
    }

    /// A group is described either by a device record that owns an `itemGroup` or by a
    /// standalone record in ItemGroups.data; both become one kind of parent here.
    private func resolveGroupParents(rawBySource: [FMIPCacheFile: [[String: Any]]],
                                     logger: LogStore) -> GroupParents {
        let deviceRecords = rawBySource[.devices] ?? []
        let deviceParentIDs = Set(deviceRecords.compactMap { raw -> String? in
            guard raw["itemGroup"] is [String: Any] else { return nil }
            return (raw["baUUID"] as? String).nonNullish
        })
        let adopted = groupParentRecords(fromItemGroups: rawBySource[.itemGroups] ?? [],
                                         existingParentIDs: deviceParentIDs)
        let records = deviceRecords + adopted

        // Which file the groups came from. Both sources are reduced to one shape, so nothing
        // downstream can tell them apart — and neither could anyone reading a log.
        logger.debug("Group sources: \(deviceParentIDs.count) embedded in Devices.data, "
            + "\(adopted.count) adopted from ItemGroups.data")

        for record in records {
            guard let group = record["itemGroup"] as? [String: Any],
                  let sizes = Self.clusterSizes(group) else { continue }
            let name = (record["name"] as? String) ?? "?"
            logger.debug("- Group \(name): groupedItemIdentifiers \(sizes)")
        }

        return GroupParents(records: records,
                            parentIDMap: buildGroupParentIDs(rawDevices: records))
    }

    /// Raw records to `DevicePoint`s, threading the group map for items only — parents
    /// themselves carry no `parentID`.
    private func parseDevicePoints(rawBySource: [FMIPCacheFile: [[String: Any]]],
                                   groupParentIDs: [String: String]) -> [FMIPCacheFile: [DevicePoint]] {
        var devicesBySource: [FMIPCacheFile: [DevicePoint]] = [:]
        for (file, arr) in rawBySource {
            // ItemGroups records describe a group, not a device: no position, and not a
            // device that failed to report, so they stay out of the per-source counts.
            guard file != .itemGroups else { continue }
            let map = (file == .items) ? groupParentIDs : [:]
            let points = cacheDecryptor.parseDeviceArray(arr, groupParentIDs: map)
            devicesBySource[file, default: []].append(contentsOf: points)
        }
        return devicesBySource
    }

    /// Give each group parent a position from its pieces where its own is stale or absent,
    /// then record whether the pieces are together. Runs whenever there are children, not
    /// only when a parent parsed: a parent with no position never parses, and it is the one
    /// that most needs reviving — without it the whole group vanishes from both lists.
    private func applyGroupPositions(to devicesBySource: [FMIPCacheFile: [DevicePoint]],
                                     rawBySource: [FMIPCacheFile: [[String: Any]]],
                                     groups: GroupParents,
                                     settings: SettingsStore,
                                     logger: LogStore) -> [FMIPCacheFile: [DevicePoint]] {
        let parentIDs = groups.parentIDs
        guard let items = devicesBySource[.items], !items.isEmpty, !parentIDs.isEmpty else {
            return devicesBySource
        }

        let devices = devicesBySource[.devices] ?? []
        let backfilled = backfillParentLocations(
            parents: devices.filter { parentIDs.contains($0.id) },
            children: items,
            rawDevices: groups.records,
            rawItems: rawBySource[.items] ?? [],
            syncInterval: settings.updateIntervalSec
        )
        let points = backfilled.points
        let backfilledByID = Dictionary(uniqueKeysWithValues: points.map { ($0.id, $0) })
        let known = Set(devices.map(\.id))
        let merged = devices.map { backfilledByID[$0.id] ?? $0 }
            + points.filter { !known.contains($0.id) }

        // Whether the pieces are in the same place decides whether the group's coordinate
        // stands for the pair at all, so it is computed once here, after the position is
        // settled, and travels with the entity.
        let childrenByParent = Dictionary(grouping: items.compactMap { child -> (String, DevicePoint)? in
            guard let pid = child.parentID else { return nil }
            return (pid, child)
        }, by: { $0.0 }).mapValues { $0.map(\.1) }

        var result = devicesBySource
        result[.devices] = merged.map { device in
            guard parentIDs.contains(device.id) else { return device }
            let children = childrenByParent[device.id] ?? []
            let status = separationStatus(children: children,
                                          syncInterval: settings.updateIntervalSec)
            // Where each piece is, published only while they are apart, so its presence is
            // itself the signal.
            let pieces = status == "separated" ? Self.pieceSummaries(children) : nil
            return device.withRichAttributes(
                (device.richAttributes ?? .empty).naming(separation: status, pieces: pieces))
        }

        // A grouped child the backfill could not match leaves its group holding whatever
        // position it already had. Silent, that is a run where every group is wrong and
        // nothing says so.
        if !backfilled.unresolvedChildren.isEmpty {
            for child in backfilled.unresolvedChildren {
                logger.debug("- Grouped child \(child.id) is in group " +
                             "\(child.groupIdentifier) but matched no parsed record")
            }
            logger.info("Grouping: \(backfilled.unresolvedChildren.count) " +
                        "grouped item\(backfilled.unresolvedChildren.count == 1 ? "" : "s") " +
                        "could not be matched; their group keeps its own position")
        }
        return result
    }

    /// The parsed devices and items, tagged by source, for Tracking and the
    /// Status window. Friends are added later by the plan.
    private func publishLocatedEntries(_ devicesBySource: [FMIPCacheFile: [DevicePoint]],
                                       to app: AppModel) {
        let allDevices = Array(devicesBySource.values.joined())
        var allEntries: [LocatedEntry] = []
        allEntries.reserveCapacity(allDevices.count)
        for (file, list) in devicesBySource {
            let src: DeviceSource = (file == .devices) ? .device : .item
            for d in list {
                allEntries.append(LocatedEntry(point: d, source: src))
            }
        }
        app.lastLocatedDevices = allDevices
        app.lastLocatedEntries = allEntries
    }

    /// One entry per piece: what it is, where, and how old that is. The age travels with
    /// the address because an address without its freshness is the same trap as `isOld`
    /// without `location_timestamp`. A piece with no address is still listed.
    nonisolated static func pieceSummaries(_ children: [DevicePoint]) -> [[String: String]]? {
        let now = Date()
        let entries = children.compactMap { child -> [String: String]? in
            var entry: [String: String] = ["name": child.name]
            if let address = child.richAttributes?.address { entry["address"] = address }
            if let at = child.richAttributes?.timestamp {
                entry["age"] = Self.ageDescription(now.timeIntervalSince(at) / 3600)
            }
            // Name alone says nothing worth publishing.
            return entry.count > 1 ? entry : nil
        }
        return entries.isEmpty ? nil : entries
    }
}
