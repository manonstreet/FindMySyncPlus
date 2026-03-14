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
    private let mqttClient = MQTTClient()

    var mqtt: MQTTClient { mqttClient }

    private weak var settings: SettingsStore?
    private weak var logger: LogStore?
    private weak var app: AppModel?

    func bind(settings: SettingsStore, logger: LogStore, app: AppModel) {
        self.settings = settings
        self.logger = logger
        self.app = app
        mqttClient.bind(logger: logger)
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

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func run(kind: RunKind, dryRun: Bool) async {
        guard let settings, let logger, let app else { return }

        let t0 = Date()

        app.beginRun(kind: kind, dryRun: dryRun)
        defer {
            app.markRunFinished()
            app.resetAfterRun()
            app.currentRunMode = .normal
        }

        await cacheDecryptor.ensureFMIPKey(logger: logger)
        if settings.enableFriends {
            await localStorageDecryptor.ensureKey(logger: logger)
            await cacheDecryptor.ensureFMFKey(logger: logger)
        }

        // --- Source summary ---
        let srcDevices = settings.enableDevices ? "Devices \u{2713}" : "Devices (off)"
        let srcItems = settings.enableItems ? "Items \u{2713}" : "Items (off)"
        let srcFriends = settings.enableFriends ? "Friends \u{2713}" : "Friends (off)"
        logger.debug("Sources: \(srcDevices), \(srcItems), \(srcFriends)")

        if dryRun { logger.info("[DRY] Beginning run") }

        // --- Pre-flight ---
        let candidates: [FMIPCacheFile] = {
            var list: [FMIPCacheFile] = []
            if settings.enableDevices { list.append(.devices) }
            if settings.enableItems   { list.append(.items) }
            return list
        }()
        let hasFMIPSources = !candidates.isEmpty
        let hasFriendSource = settings.enableFriends

        if !hasFMIPSources && !hasFriendSource {
            logger.info("All sources are disabled; nothing to do this run.")
            return
        }

        if hasFMIPSources {
            guard await runPreflight(using: candidates, settings: settings, logger: logger, dryRun: dryRun) else { return }
        }

        // --- Optional Find My refresh/kill ---
        if settings.autoLaunchKillFindMy {
            if dryRun {
                logger.info("[DRY] Would refresh Find My (launch/kill)")
            } else {
                await FindMyRefresher.refreshBlocking(
                    logger: logger,
                    enabled: true,
                    waitSeconds: settings.findMyWaitSeconds
                )
            }
        }

        // --- Read/decrypt/parse FMIP caches (post-refresh) ---
        var io: IOPhase?
        if hasFMIPSources {
            do {
                io = try await readAndParseCaches(
                    candidates: candidates,
                    settings: settings,
                    logger: logger
                )
            } catch DecryptorError.incorrectKey {
                settings.fmipKeyStatus = .invalid
                logger.error(DecryptorError.incorrectKey.localizedDescription)
                return
            } catch DecryptorError.fdaRequired {
                logger.error("\(FMIPCacheFile.devices.displayName) or \(FMIPCacheFile.items.displayName) cache requires Full Disk Access.")
                return
            } catch {
                logger.warn(error.localizedDescription)
                return
            }
            if let ioVal = io, ioVal.hadSuccessfulDecrypt {
                settings.fmipKeyStatus = .valid
            } else if hasFMIPSources && !hasFriendSource {
                logger.warn("No enabled caches produced usable data; aborting run.")
                return
            }
        }

        // --- Read friend locations ---
        var friendEntries: [DevicePoint] = []
        if hasFriendSource {
            switch await localStorageDecryptor.readFriendLocations(logger: logger) {
            case .success(let friends):
                friendEntries = friends
                settings.localStorageKeyStatus = .valid
                logger.info("Friends: found \(friends.count) friend location(s)")
            case .failure(.keyNotLoaded):
                logger.error("Unexpected: LocalStorage key not loaded despite Friends being enabled")
            case .failure(.incorrectKey):
                settings.localStorageKeyStatus = .invalid
                logger.error("Friends: LocalStorage key is incorrect.")
            case .failure(.dbNotFound):
                logger.debug("Friends: LocalStorage.db not found; skipping.")
            case .failure(.fdaRequired):
                logger.error("Friends: Full Disk Access required to read LocalStorage.db.")
            case .failure(let e):
                logger.warn("Friends: \(e.localizedDescription)")
            }
        }

        // Enrich friend names from FMF contact cache (DSID → display name)
        if !friendEntries.isEmpty {
            if let fmfNames = await cacheDecryptor.readFMFContactNames(logger: logger) {
                settings.fmfKeyStatus = .valid
                if !fmfNames.isEmpty {
                    friendEntries = friendEntries.map { entry in
                        if let displayName = fmfNames[entry.id] {
                            return DevicePoint(id: entry.id, name: displayName,
                                               latitude: entry.latitude, longitude: entry.longitude,
                                               accuracy: entry.accuracy, battery: entry.battery,
                                               prsId: entry.prsId)
                        }
                        return entry
                    }
                    logger.debug("Friends: enriched names from FMF contacts (\(fmfNames.count) available)")
                }
            }
        }

        // Abort if neither source produced data
        let hadFMIPData = io?.hadSuccessfulDecrypt ?? false
        if !hadFMIPData && friendEntries.isEmpty {
            if hasFMIPSources {
                logger.warn("No enabled sources produced usable data; aborting run.")
            }
            return
        }

        // --- Build plan & log ---
        let plan = buildPlanAndLog(
            devicesBySource: io?.devicesBySource ?? [:],
            rawBySource: io?.rawBySource ?? [:],
            friendEntries: friendEntries,
            settings: settings,
            logger: logger,
            allowAutoLearn: (settings.autoLearnUUIDs && !dryRun)
        )
        let toPost = plan.toPost
        let aliasByUUID = plan.aliasByUUID

        // --- Plan summary (before posting) ---
        let planDiscovered = plan.metrics.discoveredDevices + plan.metrics.discoveredItems + plan.metrics.discoveredFriends
        let planLocated    = plan.metrics.locatedDevices + plan.metrics.locatedItems + plan.metrics.locatedFriends
        let planToPost     = plan.metrics.toPostCount
        let planUnassigned = plan.metrics.unassignedCount
        let planNoLocation = plan.metrics.noLocationCount

        var summaryParts = [
            "discovered=\(planDiscovered)",
            "located=\(planLocated)",
            "\(dryRun ? "would_post" : "to_post")=\(planToPost)",
            "unassigned=\(planUnassigned)"
        ]
        if planNoLocation > 0 { summaryParts.append("no_location=\(planNoLocation)") }
        if plan.metrics.locatedFriends > 0 { summaryParts.append("friends=\(plan.metrics.locatedFriends)") }
        let summary = summaryParts.joined(separator: " ")
        logger.debug(dryRun ? "[DRY] Summary — \(summary)" : "Plan — \(summary)")

        let postSummary: PostSummary
        switch settings.transportMode {
        case .rest:
            postSummary = await HAClient.post(toPost,
                                              aliasByUUID: aliasByUUID,
                                              settings: settings,
                                              logger: logger,
                                              dryRun: dryRun)
        case .mqtt:
            postSummary = await mqttClient.post(toPost,
                                                aliasByUUID: aliasByUUID,
                                                settings: settings,
                                                logger: logger,
                                                dryRun: dryRun)
        }

        if !dryRun {
            logger.debug("Result — posted=\(postSummary.successCount) auth_rejected=\(postSummary.authRejectedCount) transient=\(postSummary.transientCount)")
        }

        let trackedCount = planToPost
        let postedCount = postSummary.successCount

        // Promote/demote auth status based on real posts (REST only, never in dry run)
        if !dryRun && settings.transportMode == .rest {
            if postSummary.successCount > 0 {
                updateEndpointAuthStatus(outcome: .success, dryRun: false)
            } else if postSummary.authRejectedCount > 0 {
                updateEndpointAuthStatus(outcome: .authRejected, dryRun: false)
            } // else only transients → no change
        }

        let elapsed = Date().timeIntervalSince(t0)
        let elapsedStr = String(format: "%.2f", elapsed)

        if dryRun {
            logger.info("[DRY] Finished run — \(summary) elapsed=\(elapsedStr)s")
        } else {
            var parts = [
                "discovered=\(planDiscovered)",
                "unassigned=\(planUnassigned)",
                "located=\(planLocated)",
                "tracked=\(trackedCount)",
                "posted=\(postSummary.successCount)"
            ]
            if planNoLocation > 0 { parts.append("no_location=\(planNoLocation)") }
            if plan.metrics.locatedFriends > 0 { parts.append("friends=\(plan.metrics.locatedFriends)") }
            logger.info("Finished run — " + parts.joined(separator: " ") + " elapsed=\(elapsedStr)s")

            if !app.lastRunHadWarnings { app.totalRunsCount += 1 }
            app.postedUpdatesCount += postedCount
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

        for file in candidates {
            switch await cacheDecryptor.readEncryptedPayload(from: file, logger: logger) {
            case .success(let data):
                switch await cacheDecryptor.decryptPayload(data, logger: logger) {
                case .success(let plaintext):
                    switch cacheDecryptor.parsePlistData(plaintext) {
                    case .success(let arr):
                        rawBySource[file, default: []].append(contentsOf: arr)
                        let points = cacheDecryptor.parseDeviceArray(arr)
                        devicesBySource[file, default: []].append(contentsOf: points)
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

        for d in allDevices {
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

        let metrics = RunMetrics(
            discoveredDevices: discoveredDevices,
            discoveredItems: discoveredItems,
            discoveredFriends: discoveredFriends,
            locatedDevices: locatedDevices,
            locatedItems: locatedItems,
            locatedFriends: friendEntries.count(where: { !familyDSIDs.contains($0.id.normalized()) }),
            unassignedCount: unassignedCount,
            notTrackedCount: notTrackedCount,
            toPostCount: toPost.count,
            noLocationCount: noLocationCount
        )

        return PlanPhase(toPost: toPost, aliasByUUID: aliasByUUID, metrics: metrics)
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
                    try await HAClient.testEndpointAuthentication(settings: settings)
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
