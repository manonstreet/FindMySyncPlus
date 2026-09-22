import Foundation

// MARK: - Supporting types

/// `triggered` is a sync run asked for over MQTT. It is an ordinary run with the Find My
/// relaunch forced on, which is the one thing it adds — the target user wants the per-run
/// refresh off and still wants a way to ask for one.
enum RunKind: String { case none, scheduled, manual, triggered }

enum DeviceSource: String { case device, item, friend, group }

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

extension FMIPCacheFile {
    var displayName: String {
        switch self {
        case .devices: return "Devices"
        case .items: return "Items"
        case .itemGroups: return "ItemGroups"
        case .friendCache: return "FriendCache"
        }
    }
}

// MARK: - SyncEngine

@MainActor
final class SyncEngine {

    let cacheDecryptor = CacheDecryptor()
    private let localStorageDecryptor = LocalStorageDecryptor()
    private let restClient = RESTClient()
    private let mqttClient = MQTTClient()

    /// Whether this macOS provides friend locations at all. Injectable so the macOS 14
    /// branch can be exercised on hardware that cannot run it.
    private let friendsAvailability: FriendsAvailability

    init(friendsAvailability: FriendsAvailability = .current) {
        self.friendsAvailability = friendsAvailability
    }

    var mqtt: MQTTClient { mqttClient }
    var rest: RESTClient { restClient }

    private var transport: TransportClient {
        settings?.transportMode == .mqtt ? mqttClient : restClient
    }

    private weak var settings: SettingsStore?
    private weak var logger: LogStore?
    weak var app: AppModel?

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
        let hasFriendSource = friendsAvailability.isEnabled(userToggle: settings.enableFriends)

        if !hasFMIPSources && !hasFriendSource {
            logger.info("All sources are disabled; nothing to do this run.")
            return
        }

        if hasFMIPSources {
            guard await runPreflight(using: candidates, settings: settings, logger: logger, dryRun: dryRun) else { return }
        }

        let findMyLaunched = await refreshFindMyIfNeeded(kind: kind, settings: settings,
                                                        logger: logger, dryRun: dryRun)

        let io = await readCaches(candidates: candidates, hasFMIPSources: hasFMIPSources,
                                  hasFriendSource: hasFriendSource, settings: settings, logger: logger)
        guard io != nil || hasFriendSource else { return }

        var friendEntries = await readFriends(enabled: hasFriendSource, settings: settings, logger: logger)
        friendEntries = await enrichFriendNames(friendEntries, enabled: hasFriendSource,
                                                settings: settings, logger: logger)

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

        let status = StatusRun(startedAt: t0, metrics: plan.metrics,
                               postSummary: postSummary, dryRun: dryRun,
                               findMyLaunched: findMyLaunched,
                               cacheWritten: FMIPCacheFile.newestWrite(among: candidates))

        logRunComplete(status, app: app, logger: logger)
        publishStatusEntity(status, settings: settings, logger: logger, app: app)
    }

    // MARK: - Run pipeline helpers

    private func ensureKeys(settings: SettingsStore, logger: LogStore) async {
        await cacheDecryptor.ensureFMIPKey(logger: logger)
        // Both keys serve Friends only, so an unsupported macOS needs neither.
        if friendsAvailability.isEnabled(userToggle: settings.enableFriends) {
            await localStorageDecryptor.ensureKey(logger: logger)
            await cacheDecryptor.ensureFMFKey(logger: logger)
        }
    }

    private func logSources(settings: SettingsStore, logger: LogStore) {
        let srcDevices = settings.enableDevices ? "Devices \u{2713}" : "Devices (off)"
        let srcItems = settings.enableItems ? "Items \u{2713}" : "Items (off)"
        // Distinguish "you switched it off" from "this macOS does not provide it",
        // so the line never reads as a user choice the user did not make.
        let srcFriends: String
        if !friendsAvailability.isSupported {
            srcFriends = "Friends (needs macOS 15+)"
        } else {
            srcFriends = settings.enableFriends ? "Friends \u{2713}" : "Friends (off)"
        }
        logger.debug("Sources: \(srcDevices), \(srcItems), \(srcFriends)")
    }

    private func buildCandidates(settings: SettingsStore) -> [FMIPCacheFile] {
        var list: [FMIPCacheFile] = []
        if settings.enableDevices { list.append(.devices) }
        if settings.enableItems   { list.append(.items) }
        // A group only groups items, so it follows the Items toggle rather than getting
        // one of its own. Deliberately last: pre-flight stops at the first readable
        // cache, so a machine without this file never reaches it and never logs about
        // it. On the ones that do have it, the read path treats absent as nothing.
        if settings.enableItems   { list.append(.itemGroups) }
        return list
    }

    /// - Returns: whether Find My was actually relaunched, which the status entity and
    ///   the run line both report. The cache advances because we launch Find My, so
    ///   "the cache did not move" is only a finding once you know we asked it to.
    @discardableResult
    private func refreshFindMyIfNeeded(kind: RunKind, settings: SettingsStore,
                                       logger: LogStore, dryRun: Bool) async -> Bool {
        // A triggered run refreshes whatever the toggle says. That is the entire point of
        // the trigger: the refresh is otherwise all-runs-or-no-runs, and the person asking
        // for it wants it off for the scheduled ones.
        guard settings.autoLaunchKillFindMy || kind == .triggered else { return false }
        if dryRun {
            logger.info("[DRY] Would refresh Find My (launch/kill)")
            return false
        }
        await FindMyRefresher.refreshBlocking(
            logger: logger, enabled: true, waitSeconds: settings.findMyWaitSeconds
        )
        return true
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

    private func enrichFriendNames(_ entries: [DevicePoint], enabled: Bool,
                                   settings: SettingsStore, logger: LogStore) async -> [DevicePoint] {
        // Gated on the source, not on having friends to enrich. The key either decrypts
        // or it does not, and that is true whether or not anyone is sharing a location —
        // bailing on an empty list left the indicator unvalidated forever for someone
        // with no friends shared, which is the last case of #19's unclearable light.
        // Gating on `enabled` still matters: with Friends off the key is not consulted,
        // so the indicator reads "not applicable" rather than going green.
        guard enabled else { return entries }
        guard let fmfNames = await cacheDecryptor.readFMFContactNames(logger: logger) else { return entries }
        settings.fmfKeyStatus = .valid
        guard !entries.isEmpty, !fmfNames.isEmpty else { return entries }
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

    /// Takes the same `StatusRun` the status entity is built from, so the line a reporter
    /// pastes and the attributes Home Assistant shows can never disagree — and so the run's
    /// inputs sit beside its outcome on one row rather than in two places.
    private func logRunComplete(_ run: StatusRun, app: AppModel, logger: LogStore) {
        let m = run.metrics
        let elapsed = String(format: "%.2f", Date().timeIntervalSince(run.startedAt))

        var parts = [
            "discovered=\(m.discoveredDevices + m.discoveredItems + m.discoveredFriends)"
        ]
        if run.dryRun {
            parts += [
                "located=\(m.locatedDevices + m.locatedItems + m.locatedFriends)",
                "would_post=\(m.toPostCount)",
                "unassigned=\(m.unassignedCount)"
            ]
        } else {
            parts += [
                "unassigned=\(m.unassignedCount)",
                "located=\(m.locatedDevices + m.locatedItems + m.locatedFriends)",
                "tracked=\(m.toPostCount)",
                "posted=\(run.postSummary.successCount)"
            ]
            if run.postSummary.skippedUnchangedCount > 0 {
                parts.append("skipped_unchanged=\(run.postSummary.skippedUnchangedCount)")
            }
        }
        if m.noLocationCount > 0 { parts.append("no_location=\(m.noLocationCount)") }
        if m.locatedFriends > 0 { parts.append("friends=\(m.locatedFriends)") }

        // The two freshness inputs, raw and beside the outcome they explain. Without
        // `find_my`, "the cache did not move" reads as a fault when it may be a setting.
        parts.append("find_my=\(run.findMyLaunched ? "launched" : "not_launched")")
        if let written = run.cacheWritten {
            let age = Date().timeIntervalSince(written) / 3600
            parts.append("cache_age=\(Self.ageDescription(age))")
        }

        let prefix = run.dryRun ? "[DRY] " : ""
        logger.info("\(prefix)Finished run — \(parts.joined(separator: " ")) elapsed=\(elapsed)s")

        guard !run.dryRun else { return }
        if !app.lastRunHadWarnings { app.totalRunsCount += 1 }
        app.postedUpdatesCount += run.postSummary.successCount
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
