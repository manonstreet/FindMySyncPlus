import Foundation

// MARK: - Supporting types

enum RunKind: String { case none, scheduled, manual }

enum DeviceSource: String { case device, item, friend }

struct LocatedEntry {
    let point: DevicePoint
    let source: DeviceSource
}

struct RunMetrics {
    let discoveredDevices: Int
    let discoveredItems: Int
    let discoveredFriends: Int
    let locatedDevices: Int
    let locatedItems: Int
    let locatedFriends: Int
    let unassignedCount: Int
    let notTrackedCount: Int
    let toPostCount: Int
    let noLocationCount: Int
}

enum AuthStatusOutcome {
    case success                 // confirmed good
    case authRejected            // 401/403
    case transient(String?)      // network/DNS/timeout/5xx/etc. (do NOT change status)
    case badConfig(String?)      // invalid URL, empty header, etc. (do NOT change status)
}

private extension FMIPCacheFile {
    var displayName: String {
        switch self {
        case .devices: return "Devices"
        case .items: return "Items"
        case .friendCache: return "FriendCache"
        }
    }
}

// MARK: - SyncEngine

@MainActor
final class SyncEngine {

    private let cacheDecryptor = CacheDecryptor()
    private let localStorageDecryptor = LocalStorageDecryptor()
    private let restClient = RESTClient()
    private let mqttClient = MQTTClient()

    var mqtt: MQTTClient { mqttClient }
    var rest: RESTClient { restClient }

    private var transport: TransportClient {
        settings?.transportMode == .mqtt ? mqttClient : restClient
    }

    private weak var settings: SettingsStore?
    private weak var logger: LogStore?
    private weak var app: AppModel?

    func bind(settings: SettingsStore, logger: LogStore, app: AppModel) {
        self.settings = settings
        self.logger = logger
        self.app = app
        mqttClient.bind(logger: logger, settings: settings)
    }

    // MARK: - Key invalidation

    func invalidateCacheDecryptorKey() {
        logger?.info("A new key was loaded; invalidating the in-memory key.")
        Task { await cacheDecryptor.invalidateKey() }
    }

    func invalidateLocalStorageKey() {
        logger?.info("A new LocalStorage key was loaded; invalidating the in-memory key.")
        Task { await localStorageDecryptor.invalidateKey() }
    }

    func invalidateFMFKey() {
        logger?.info("A new FMF key was loaded; invalidating the in-memory key.")
        Task { await cacheDecryptor.invalidateFMFKey() }
    }

    // MARK: - Auth status

    func updateEndpointAuthStatus(outcome: AuthStatusOutcome, dryRun: Bool) {
        guard let settings else { return }
        if dryRun { return }
        switch outcome {
        case .success:
            settings.endpointAuthStatus = .valid
        case .authRejected:
            settings.endpointAuthStatus = .invalid
        case .transient, .badConfig:
            break
        }
    }

    // MARK: - Internal phase types

    private struct IOPhase {
        let rawBySource: [FMIPCacheFile: [[String: Any]]]
        let devicesBySource: [FMIPCacheFile: [DevicePoint]]
        let hadSuccessfulDecrypt: Bool
    }

    private struct PlanPhase {
        let toPost: [DevicePoint]
        let aliasByUUID: [String: String]
        let metrics: RunMetrics
    }

    // MARK: - Source helpers

    private func sourceByUUIDMap(from devicesBySource: [FMIPCacheFile: [DevicePoint]]) -> [String: DeviceSource] {
        var map: [String: DeviceSource] = [:]
        for (file, list) in devicesBySource {
            let src: DeviceSource = (file == .devices) ? .device : .item
            for d in list { map[d.id.normalized()] = src }
        }
        return map
    }

    // MARK: - Run pipeline

    func run(kind: RunKind, dryRun: Bool) async {
        guard let settings, let logger, let app else { return }

        let t0 = Date()

        app.beginRun(kind: kind, dryRun: dryRun)
        defer {
            app.markRunFinished()
            app.resetAfterRun()
            app.currentRunMode = .normal
        }

        await ensureKeys(settings: settings, logger: logger)
        logSources(settings: settings, logger: logger)
        if dryRun { logger.info("[DRY] Beginning run") }

        let candidates = buildCandidates(settings: settings)
        let hasFMIPSources = !candidates.isEmpty
        let hasFriendSource = settings.enableFriends

        if !hasFMIPSources && !hasFriendSource {
            logger.info("All sources are disabled; nothing to do this run.")
            return
        }

        if hasFMIPSources {
            guard await runPreflight(using: candidates, settings: settings, logger: logger, dryRun: dryRun) else { return }
        }

        await refreshFindMyIfNeeded(settings: settings, logger: logger, dryRun: dryRun)

        let io = await readCaches(candidates: candidates, hasFMIPSources: hasFMIPSources,
                                  hasFriendSource: hasFriendSource, settings: settings, logger: logger)
        guard io != nil || hasFriendSource else { return }

        var friendEntries = await readFriends(enabled: hasFriendSource, settings: settings, logger: logger)
        friendEntries = await enrichFriendNames(friendEntries, settings: settings, logger: logger)

        let hadFMIPData = io?.hadSuccessfulDecrypt ?? false
        if !hadFMIPData && friendEntries.isEmpty {
            if hasFMIPSources { logger.warn("No enabled sources produced usable data; aborting run.") }
            return
        }

        let plan = buildPlanAndLog(
            devicesBySource: io?.devicesBySource ?? [:],
            rawBySource: io?.rawBySource ?? [:],
            friendEntries: friendEntries,
            settings: settings, logger: logger,
            allowAutoLearn: (settings.autoLearnUUIDs && !dryRun)
        )

        logPlanSummary(plan, dryRun: dryRun, logger: logger)

        let postSummary = await postAndReport(plan.toPost, aliasByUUID: plan.aliasByUUID,
                                              settings: settings, logger: logger, dryRun: dryRun)

        logRunComplete(t0: t0, plan: plan, postSummary: postSummary, dryRun: dryRun,
                       app: app, logger: logger)
    }

    // MARK: - Run pipeline helpers

    private func ensureKeys(settings: SettingsStore, logger: LogStore) async {
        await cacheDecryptor.ensureFMIPKey(logger: logger)
        if settings.enableFriends {
            await localStorageDecryptor.ensureKey(logger: logger)
            await cacheDecryptor.ensureFMFKey(logger: logger)
        }
    }

    private func logSources(settings: SettingsStore, logger: LogStore) {
        let srcDevices = settings.enableDevices ? "Devices \u{2713}" : "Devices (off)"
        let srcItems = settings.enableItems ? "Items \u{2713}" : "Items (off)"
        let srcFriends = settings.enableFriends ? "Friends \u{2713}" : "Friends (off)"
        logger.debug("Sources: \(srcDevices), \(srcItems), \(srcFriends)")
    }

    private func buildCandidates(settings: SettingsStore) -> [FMIPCacheFile] {
        var list: [FMIPCacheFile] = []
        if settings.enableDevices { list.append(.devices) }
        if settings.enableItems   { list.append(.items) }
        return list
    }

    private func refreshFindMyIfNeeded(settings: SettingsStore, logger: LogStore, dryRun: Bool) async {
        guard settings.autoLaunchKillFindMy else { return }
        if dryRun {
            logger.info("[DRY] Would refresh Find My (launch/kill)")
        } else {
            await FindMyRefresher.refreshBlocking(
                logger: logger, enabled: true, waitSeconds: settings.findMyWaitSeconds
            )
        }
    }

    private func readCaches(candidates: [FMIPCacheFile], hasFMIPSources: Bool,
                            hasFriendSource: Bool, settings: SettingsStore, logger: LogStore) async -> IOPhase? {
        guard hasFMIPSources else { return nil }
        do {
            let io = try await readAndParseCaches(candidates: candidates, settings: settings, logger: logger)
            if io.hadSuccessfulDecrypt {
                settings.fmipKeyStatus = .valid
            } else if !hasFriendSource {
                logger.warn("No enabled caches produced usable data; aborting run.")
            }
            return io
        } catch DecryptorError.incorrectKey {
            settings.fmipKeyStatus = .invalid
            logger.error(DecryptorError.incorrectKey.localizedDescription)
            return nil
        } catch DecryptorError.fdaRequired {
            logger.error("\(FMIPCacheFile.devices.displayName) or \(FMIPCacheFile.items.displayName) cache requires Full Disk Access.")
            return nil
        } catch {
            logger.warn(error.localizedDescription)
            return nil
        }
    }

    private func readFriends(enabled: Bool, settings: SettingsStore, logger: LogStore) async -> [DevicePoint] {
        guard enabled else { return [] }
        switch await localStorageDecryptor.readFriendLocations(logger: logger) {
        case .success(let friends):
            settings.localStorageKeyStatus = .valid
            logger.info("Friends: found \(friends.count) friend location(s)")
            return friends
        case .failure(.keyNotLoaded):
            logger.error("Unexpected: LocalStorage key not loaded despite Friends being enabled")
        case .failure(.incorrectKey):
            settings.localStorageKeyStatus = .invalid
            logger.error("Friends: LocalStorage key is incorrect.")
        case .failure(.dbNotFound):
            // Was .debug, which meant a machine using the other database
            // location silently produced no friends at the default log level.
            // The resolver logs which paths it checked.
            logger.warn("Friends: no readable LocalStorage.db; skipping friends this run.")
        case .failure(.fdaRequired):
            logger.error("Friends: Full Disk Access required to read LocalStorage.db.")
        case .failure(let e):
            logger.warn("Friends: \(e.localizedDescription)")
        }
        return []
    }

    private func enrichFriendNames(_ entries: [DevicePoint], settings: SettingsStore, logger: LogStore) async -> [DevicePoint] {
        guard !entries.isEmpty else { return entries }
        guard let fmfNames = await cacheDecryptor.readFMFContactNames(logger: logger) else { return entries }
        settings.fmfKeyStatus = .valid
        guard !fmfNames.isEmpty else { return entries }
        let enriched = entries.map { entry in
            if let displayName = fmfNames[entry.id] {
                return entry.with(name: displayName)
            }
            return entry
        }
        logger.debug("Friends: enriched names from FMF contacts (\(fmfNames.count) available)")
        return enriched
    }

    private func logPlanSummary(_ plan: PlanPhase, dryRun: Bool, logger: LogStore) {
        let m = plan.metrics
        var parts = [
            "discovered=\(m.discoveredDevices + m.discoveredItems + m.discoveredFriends)",
            "located=\(m.locatedDevices + m.locatedItems + m.locatedFriends)",
            "\(dryRun ? "would_post" : "to_post")=\(m.toPostCount)",
            "unassigned=\(m.unassignedCount)"
        ]
        if m.noLocationCount > 0 { parts.append("no_location=\(m.noLocationCount)") }
        if m.locatedFriends > 0 { parts.append("friends=\(m.locatedFriends)") }
        let summary = parts.joined(separator: " ")
        logger.debug(dryRun ? "[DRY] Summary — \(summary)" : "Plan — \(summary)")
    }

    private func postAndReport(_ devices: [DevicePoint], aliasByUUID: [String: String],
                               settings: SettingsStore, logger: LogStore, dryRun: Bool) async -> PostSummary {
        let postSummary = await transport.post(devices, aliasByUUID: aliasByUUID,
                                               settings: settings, logger: logger, dryRun: dryRun)
        if !dryRun {
            logger.debug("Result — posted=\(postSummary.successCount) auth_rejected=\(postSummary.authRejectedCount) transient=\(postSummary.transientCount)")

            if settings.transportMode == .rest {
                if postSummary.successCount > 0 {
                    updateEndpointAuthStatus(outcome: .success, dryRun: false)
                } else if postSummary.authRejectedCount > 0 {
                    updateEndpointAuthStatus(outcome: .authRejected, dryRun: false)
                }
            }
        }
        return postSummary
    }

    private func logRunComplete(t0: Date, plan: PlanPhase, postSummary: PostSummary,
                                dryRun: Bool, app: AppModel, logger: LogStore) {
        let m = plan.metrics
        let elapsed = String(format: "%.2f", Date().timeIntervalSince(t0))

        if dryRun {
            var parts = [
                "discovered=\(m.discoveredDevices + m.discoveredItems + m.discoveredFriends)",
                "located=\(m.locatedDevices + m.locatedItems + m.locatedFriends)",
                "would_post=\(m.toPostCount)",
                "unassigned=\(m.unassignedCount)"
            ]
            if m.noLocationCount > 0 { parts.append("no_location=\(m.noLocationCount)") }
            if m.locatedFriends > 0 { parts.append("friends=\(m.locatedFriends)") }
            logger.info("[DRY] Finished run — \(parts.joined(separator: " ")) elapsed=\(elapsed)s")
        } else {
            var parts = [
                "discovered=\(m.discoveredDevices + m.discoveredItems + m.discoveredFriends)",
                "unassigned=\(m.unassignedCount)",
                "located=\(m.locatedDevices + m.locatedItems + m.locatedFriends)",
                "tracked=\(m.toPostCount)",
                "posted=\(postSummary.successCount)"
            ]
            if m.noLocationCount > 0 { parts.append("no_location=\(m.noLocationCount)") }
            if m.locatedFriends > 0 { parts.append("friends=\(m.locatedFriends)") }
            logger.info("Finished run — \(parts.joined(separator: " ")) elapsed=\(elapsed)s")

            if !app.lastRunHadWarnings { app.totalRunsCount += 1 }
            app.postedUpdatesCount += postSummary.successCount
        }
    }

    // MARK: - Read and parse caches

    private func readAndParseCaches(
        candidates: [FMIPCacheFile],
        settings: SettingsStore,
        logger: LogStore
    ) async throws -> IOPhase {
        guard let app else { throw DecryptorError.keyNotLoaded }

        var rawBySource: [FMIPCacheFile: [[String: Any]]] = [:]
        var devicesBySource: [FMIPCacheFile: [DevicePoint]] = [:]
        var hadSuccessfulDecrypt = false

        // Phase 1 — read+decrypt each cache into raw dicts only. Parsing into
        // DevicePoint is deferred until Phase 3 so we have the full picture
        // (we need Devices.data parent groups before we can stamp parentID
        // onto Items.data children).
        for file in candidates {
            switch await cacheDecryptor.readEncryptedPayload(from: file, logger: logger) {
            case .success(let data):
                switch await cacheDecryptor.decryptPayload(data, logger: logger) {
                case .success(let plaintext):
                    switch cacheDecryptor.parsePlistData(plaintext) {
                    case .success(let arr):
                        rawBySource[file, default: []].append(contentsOf: arr)
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
                    // Silently ignore missing file
                } else if case .fdaRequired = e {
                    throw DecryptorError.fdaRequired
                } else {
                    logger.warn("\(file.displayName) read failed: \(e.localizedDescription)")
                }
            }
        }

        // Phase 2 — build groupIdentifier -> parent id map from Devices.data
        // entries that own an itemGroup (e.g. an AirPods Pro pair). Children
        // (e.g. Case, Left Bud, Right Bud) carry this same id in their
        // `groupIdentifier` field and will get parentID stamped accordingly.
        let groupParentIDs = buildGroupParentIDs(rawDevices: rawBySource[.devices] ?? [])

        // Phase 3 — parse raw -> DevicePoint, threading the group map only
        // for items (parents themselves don't need parentID).
        for (file, arr) in rawBySource {
            let map = (file == .items) ? groupParentIDs : [:]
            let points = cacheDecryptor.parseDeviceArray(arr, groupParentIDs: map)
            devicesBySource[file, default: []].append(contentsOf: points)
        }

        // Phase 4 — backfill stale parent locations from their freshest child.
        // Parent group entries from Devices.data sometimes carry a stale
        // location (isOld=true) while their children in Items.data have fresh
        // ones; use the children's data so the parent entity reflects current
        // location.
        if let devices = devicesBySource[.devices], !devices.isEmpty,
           let items = devicesBySource[.items], !items.isEmpty {
            let parentIDs: Set<String> = Set(
                (rawBySource[.devices] ?? []).compactMap { raw -> String? in
                    guard raw["itemGroup"] is [String: Any] else { return nil }
                    return (raw["baUUID"] as? String).nonNullish
                }
            )
            let parents = devices.filter { parentIDs.contains($0.id) }
            if !parents.isEmpty {
                let backfilled = backfillParentLocations(
                    parents: parents,
                    children: items,
                    rawDevices: rawBySource[.devices] ?? [],
                    rawItems: rawBySource[.items] ?? []
                )
                let backfilledByID = Dictionary(uniqueKeysWithValues: backfilled.map { ($0.id, $0) })
                devicesBySource[.devices] = devices.map { backfilledByID[$0.id] ?? $0 }
            }
        }

        // Update UI with merged devices and entries tagged with source
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

        return IOPhase(
            rawBySource: rawBySource,
            devicesBySource: devicesBySource,
            hadSuccessfulDecrypt: hadSuccessfulDecrypt
        )
    }

    /// Maps each grouped child's `groupIdentifier` to the parent device's id.
    /// A parent device entry in Devices.data is identified by the presence of
    /// an `itemGroup` dict; the parent's id is its `baUUID`. The child's
    /// `groupIdentifier` field carries the same string, so the map's key and
    /// value are identical.
    private func buildGroupParentIDs(rawDevices: [[String: Any]]) -> [String: String] {
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
    nonisolated func backfillParentLocations(
        parents: [DevicePoint],
        children: [DevicePoint],
        rawDevices: [[String: Any]],
        rawItems: [[String: Any]]
    ) -> [DevicePoint] {
        guard !parents.isEmpty else { return parents }

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
        return parents.map { parent in
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

    // MARK: - Build plan and log

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

    private func buildPlanAndLog(
        devicesBySource: [FMIPCacheFile: [DevicePoint]],
        rawBySource: [FMIPCacheFile: [[String: Any]]],
        friendEntries: [DevicePoint] = [],
        settings: SettingsStore,
        logger: LogStore,
        allowAutoLearn: Bool
    ) -> PlanPhase {
        guard let app else {
            return PlanPhase(toPost: [], aliasByUUID: [:], metrics: RunMetrics(
                discoveredDevices: 0, discoveredItems: 0, discoveredFriends: 0,
                locatedDevices: 0, locatedItems: 0, locatedFriends: 0,
                unassignedCount: 0, notTrackedCount: 0, toPostCount: 0, noLocationCount: 0))
        }

        // Per-source counts
        let discoveredDevices = rawBySource[.devices]?.count ?? 0
        let discoveredItems   = rawBySource[.items]?.count ?? 0
        let discoveredFriends = friendEntries.count
        let locatedDevices    = devicesBySource[.devices]?.count ?? 0
        let locatedItems      = devicesBySource[.items]?.count ?? 0

        // Build a fast UUID -> alias record map once for this plan
        var aliasByUUIDLocal: [String: DeviceAlias] = [:]
        aliasByUUIDLocal.reserveCapacity(settings.aliases.count * 2)
        for a in settings.aliases {
            for u in a.knownUUIDs { aliasByUUIDLocal[u] = a }
        }

        // Build a source map once using shared helper, plus friends
        var sourceMap = sourceByUUIDMap(from: devicesBySource)
        for f in friendEntries { sourceMap[f.id.normalized()] = .friend }

        func label(for src: DeviceSource?) -> String {
            switch src {
            case .item: return "Item"
            case .friend: return "Friend"
            default: return "Device"
            }
        }

        // No-location metric (from raw arrays) — compact guard style
        let decryptedArray = (rawBySource[.devices] ?? []) + (rawBySource[.items] ?? [])
        var noLocationCount = 0
        for raw in decryptedArray {
            let id = normalizeID(raw["baUUID"]) ?? normalizeID(raw["deviceDiscoveryId"])
            let hasValidLocation: Bool = {
                guard let loc = raw["location"] as? [String: Any],
                      loc["latitude"] is Double,
                      loc["longitude"] is Double,
                      loc["horizontalAccuracy"] is Double
                else { return false }
                return true
            }()
            if !hasValidLocation, let id {
                let name = (raw["name"] as? String) ?? ""
                logger.debug("- \(name) (\(id)) has no location")
                noLocationCount += 1
            }
        }

        // Single pass over all FMIP devices to build plan and metrics
        let allDevices = Array(devicesBySource.values.joined())
        var toPost: [DevicePoint] = []
        var aliasByUUID: [String: String] = [:]
        var unassignedCount = 0
        var notTrackedCount = 0
        var lastSeenNameUpdates: [(aliasKey: String, name: String)] = []

        // Collect family DSIDs from FMIP device entries for friend dedup.
        var familyDSIDs: Set<String> = []
        for devices in devicesBySource.values {
            for d in devices {
                if let prs = d.prsId, prs != "owner" {
                    familyDSIDs.insert(prs.normalized())
                }
            }
        }

        // Build rich-attribute lookup from friend entries for family merge
        var friendRichByDSID: [String: RichLocationAttributes] = [:]
        for f in friendEntries {
            if let rich = f.richAttributes {
                friendRichByDSID[f.id.normalized()] = rich
            }
        }

        for d in allDevices {
            // Merge rich attributes from LocalStorage friend data onto family FMIP devices
            var d = d
            if let prs = d.prsId, prs != "owner",
               let friendRich = friendRichByDSID[prs.normalized()],
               d.richAttributes == nil {
                d = d.with(richAttributes: friendRich)
            }
            let uuid = d.id.normalized()
            let srcLabel = label(for: sourceMap[uuid])

            if let rec = aliasByUUIDLocal[uuid] {
                if !d.name.isEmpty {
                    lastSeenNameUpdates.append((aliasKey: rec.alias, name: d.name))
                }

                logDevice(d, source: srcLabel, alias: rec.alias, tracked: rec.tracked, logger: logger)
                if rec.tracked {
                    toPost.append(d)
                    aliasByUUID[uuid] = rec.alias
                } else {
                    notTrackedCount += 1
                }
            } else {
                var learnedAlias: DeviceAlias? = nil
                if allowAutoLearn, !d.name.isEmpty {
                    if let matchIdx = settings.aliases.firstIndex(where: { ($0.lastSeenName ?? "").caseInsensitiveCompare(d.name) == .orderedSame }) {
                        let aliasKey = settings.aliases[matchIdx].alias
                        let evicted = settings.updateAliasWithCap(aliasKey, addUUID: d.id, lastSeenName: d.name)
                        if let updated = settings.aliases.first(where: { $0.alias == aliasKey }) {
                            learnedAlias = updated
                            aliasByUUIDLocal[d.id.normalized()] = updated
                            if !evicted.isEmpty {
                                logger.debug("Alias \"\(aliasKey)\" reached cap; evicted \(evicted.count) old UUID(s)")
                            }
                            logger.info("Auto-learned UUID \(d.id.normalized()) for alias \"\(aliasKey)\" (name match)")
                            app.learnedUUIDsCount &+= 1
                        }
                    }
                }

                if let rec = learnedAlias {
                    logDevice(d, source: srcLabel, alias: rec.alias, tracked: rec.tracked, logger: logger)
                    if rec.tracked {
                        toPost.append(d)
                        aliasByUUID[uuid] = rec.alias
                    } else {
                        notTrackedCount += 1
                    }
                } else {
                    logDevice(d, source: srcLabel, alias: nil, tracked: false, logger: logger)
                    unassignedCount += 1
                }
            }
        }

        // --- Process friend entries ---
        for f in friendEntries {
            let friendID = f.id.normalized()

            if familyDSIDs.contains(friendID) {
                logger.debug("Friend \"\(f.name.isEmpty ? f.id : f.name)\" is a family member (DSID match) — skipping (devices already tracked)")
                continue
            }

            if let rec = aliasByUUIDLocal[friendID] {
                if !f.name.isEmpty {
                    lastSeenNameUpdates.append((aliasKey: rec.alias, name: f.name))
                }
                logDevice(f, source: "Friend", alias: rec.alias, tracked: rec.tracked, logger: logger)
                if rec.tracked {
                    toPost.append(f)
                    aliasByUUID[friendID] = rec.alias
                } else {
                    notTrackedCount += 1
                }
            } else {
                logDevice(f, source: "Friend", alias: nil, tracked: false, logger: logger)
                unassignedCount += 1
            }
        }

        // Flush all lastSeenName updates in a single storage write
        settings.batchUpdateLastSeenNames(lastSeenNameUpdates)

        // Update UI with merged entries including non-family friends
        var allEntries = app.lastLocatedEntries
        for f in friendEntries where !familyDSIDs.contains(f.id.normalized()) {
            allEntries.append(LocatedEntry(point: f, source: .friend))
        }
        app.lastLocatedEntries = allEntries
        app.lastLocatedDevices = allEntries.map(\.point)

        // Drop unaliased grouped children from posting. The parent group
        // entity is the canonical "AirPods" (or similar) for HA; sub-items
        // only publish if the user has explicitly aliased them.
        let filteredToPost = filterUnaliasedGroupedChildren(toPost, aliasByUUID: aliasByUUID)
        let droppedChildren = toPost.count - filteredToPost.count
        if droppedChildren > 0 {
            logger.debug("Skipped \(droppedChildren) unaliased grouped child entr\(droppedChildren == 1 ? "y" : "ies") from posting.")
        }

        let metrics = RunMetrics(
            discoveredDevices: discoveredDevices,
            discoveredItems: discoveredItems,
            discoveredFriends: discoveredFriends,
            locatedDevices: locatedDevices,
            locatedItems: locatedItems,
            locatedFriends: friendEntries.count(where: { !familyDSIDs.contains($0.id.normalized()) }),
            unassignedCount: unassignedCount,
            notTrackedCount: notTrackedCount,
            toPostCount: filteredToPost.count,
            noLocationCount: noLocationCount
        )

        return PlanPhase(toPost: filteredToPost, aliasByUUID: aliasByUUID, metrics: metrics)
    }

    // MARK: - Preflight

    private func runPreflight(using candidates: [FMIPCacheFile],
                              settings: SettingsStore,
                              logger: LogStore,
                              dryRun: Bool) async -> Bool {
        // 1) Try enabled caches in order to ensure at least one is readable
        var preflightEncrypted: Data? = nil
        preflightLoop: for file in candidates {
            switch await cacheDecryptor.readEncryptedPayload(from: file, logger: logger) {
            case .success(let data):
                preflightEncrypted = data
                logger.debug("Pre-flight check passed: \(file.displayName) cache is readable.")
                break preflightLoop
            case .failure(let e):
                logger.error(e.localizedDescription)
                if case .fdaRequired = e {
                    return false
                } else {
                    continue
                }
            }
        }
        guard let preflightData = preflightEncrypted else {
            logger.error("Pre-flight failed: No enabled cache could be read.")
            return false
        }

        // 2) Key validity
        switch await cacheDecryptor.decryptPayload(preflightData, logger: logger) {
        case .success:
            logger.debug("Pre-flight check passed: Decryption key is valid.")
        case .failure(.incorrectKey):
            settings.fmipKeyStatus = .invalid
            logger.error(DecryptorError.incorrectKey.localizedDescription)
            return false
        case .failure(let otherError):
            logger.error(otherError.localizedDescription)
            return false
        }

        // 3) Transport connectivity (normal runs only)
        if dryRun {
            logger.info("[DRY] Skipping pre-flight transport test")
        } else {
            switch settings.transportMode {
            case .rest:
                if settings.endpointAuth.isEmpty {
                    settings.endpointAuthStatus = .notSet
                }
                do {
                    try await restClient.testEndpointAuthentication(settings: settings)
                    updateEndpointAuthStatus(outcome: .success, dryRun: false)
                    logger.debug("Pre-flight check passed: Endpoint authentication is valid.")
                } catch let auth as AuthError {
                    switch auth {
                    case .authRejected:
                        updateEndpointAuthStatus(outcome: .authRejected, dryRun: false)
                        logger.error(auth.localizedDescription)
                        return false
                    case .requestFailed(let status) where (500...599).contains(status):
                        logger.warn("Pre-flight auth check: endpoint unavailable (HTTP \(status)). Aborting run.")
                        return false
                    case .networkError:
                        logger.warn("Pre-flight auth check: network error. Aborting run. \(auth.localizedDescription)")
                        return false
                    default:
                        logger.warn("Pre-flight auth check warning: \(auth.localizedDescription). Aborting run.")
                        return false
                    }
                } catch {
                    logger.warn("Pre-flight auth check warning: \(error.localizedDescription). Aborting run.")
                    return false
                }
            case .mqtt:
                let connected = await mqttClient.ensureConnected(settings: settings)
                if connected {
                    logger.debug("Pre-flight check passed: MQTT broker connected.")
                } else {
                    logger.warn("Pre-flight: MQTT broker not reachable. Aborting run.")
                    return false
                }
            }
        }
        return true
    }
}
