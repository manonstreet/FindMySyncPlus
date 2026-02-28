import Foundation
import Combine
import SwiftUI

private let runDateFormatter: DateFormatter = {
    let df = DateFormatter()
    df.dateStyle = .short
    df.timeStyle = .medium
    return df
}()

fileprivate extension FMIPCacheFile {
    var displayName: String { self == .devices ? "Devices" : "Items" }
}

@MainActor
final class AppModel: NSObject, ObservableObject {

    enum RunKind: String { case none, scheduled, manual }
    enum RunMode: String { case normal, dry }
    @Published var currentRunMode: RunMode = .normal
    @Published var isPerformingRun: Bool = false
    @Published var currentRunKind: RunKind = .none
    @Published var isRunning = false
    @Published private(set) var lastRun: Date?
    @Published private(set) var nextRun: Date?
    @Published var lastRunHadFatalError: Bool = false
    @Published private(set) var lastRunHadWarnings: Bool = false
    @Published var runWarningsCount: Int = 0
    @Published var schedulerStartDate: Date? = nil
    @Published var totalRunsCount: Int = 0
    @Published var postedUpdatesCount: Int = 0
    @Published var learnedUUIDsCount: Int = 0
    @Published var lastLocatedDevices: [DevicePoint] = []
    @Published var lastLocatedEntries: [LocatedEntry] = []

    var decryptor = Decryptor()
    private var timerTask: Task<Void, Never>?
    private weak var settings: SettingsStore?
    private weak var logger: LogStore?

    private var cancellables = Set<AnyCancellable>()
    private var lastScheduledIntervalSec: Double? = nil

    override init() {
        super.init()
    }

    enum AuthStatusOutcome {
        case success                 // confirmed good
        case authRejected            // 401/403
        case transient(String?)      // network/DNS/timeout/5xx/etc. (do NOT change status)
        case badConfig(String?)      // invalid URL, empty header, etc. (do NOT change status)
    }

    @MainActor
    private func updateEndpointAuthStatus(outcome: AuthStatusOutcome, dryRun: Bool) {
        guard let settings else { return }
        if dryRun { return } // dry-run never mutates auth status
        switch outcome {
        case .success:
            settings.endpointAuthStatus = .valid
        case .authRejected:
            settings.endpointAuthStatus = .invalid
        case .transient, .badConfig:
            break
        }
    }
    
    @MainActor
    func triggerManualAuthTestAsync() async -> AuthStatusOutcome {
        guard !isPerformingRun else { return .transient("Busy") }
        guard let settings, let logger else { return .transient("Unavailable") }

        if settings.endpointAuth.isEmpty {
            settings.endpointAuthStatus = .notSet
            logger.warn("Auth Test: header not set.")
            return .badConfig("Auth header not set")
        }

        do {
            try await decryptor.testEndpointAuthentication(settings: settings)
            updateEndpointAuthStatus(outcome: .success, dryRun: false)
            logger.info("Auth Test: success")
            return .success
        } catch let auth as AuthError {
            switch auth {
            case .authRejected:
                updateEndpointAuthStatus(outcome: .authRejected, dryRun: false)
                logger.error("Auth Test: \(auth.localizedDescription)")
                return .authRejected
            case .requestFailed(let code) where (500...599).contains(code):
                logger.warn("Auth Test: \(auth.localizedDescription)")
                return .transient("HTTP \(code)")
            case .networkError:
                logger.warn("Auth Test: \(auth.localizedDescription)")
                return .transient("Network error")
            case .invalidURL(let reason):
                logger.warn(reason)
                return .badConfig(reason)
            default:
                logger.warn("Auth Test: \(auth.localizedDescription)")
                return .transient(auth.localizedDescription)
            }
        } catch {
            logger.warn("Auth Test: \(error.localizedDescription)")
            return .transient(error.localizedDescription)
        }
    }
    
    func bind(settings: SettingsStore, logger: LogStore) {
        self.settings = settings
        self.logger = logger
        logger.minimumLevel = settings.logLevel
        settings.objectWillChange
            .map { settings.updateIntervalSec }
            .removeDuplicates()
            .debounce(for: .milliseconds(1000), scheduler: DispatchQueue.main)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rescheduleIfNeeded(reason: "Interval changed") }
            .store(in: &cancellables)
        settings.$logLevel
            .sink { [weak self] level in self?.logger?.minimumLevel = level }
            .store(in: &cancellables)
        logger.errorSignal
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.handleFatalError() }
            .store(in: &cancellables)
        logger.warningSignal
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.handleWarnings() }
            .store(in: &cancellables)
        Publishers.CombineLatest3($isRunning, $isPerformingRun, $lastRunHadFatalError)
            .receive(on: RunLoop.main) // keep this
            .sink { running, performing, fatal in
                Task { @MainActor in
                    let state: DockStatusOverlay.State = fatal ? .error : (running ? .running : .stopped)
                    DockStatusOverlay.shared.update(for: state)
                }
            }
            .store(in: &cancellables)
    }
    
    func invalidateDecryptorKey() {
        logger?.info("A new key was loaded; invalidating the in-memory key.")
        Task { await decryptor.invalidateKey() }
    }
    
    private func handleFatalError() {
        stop()
        self.lastRunHadFatalError = true
    }

    private func handleWarnings() {
        if lastRunHadWarnings == false { runWarningsCount &+= 1 }
        self.lastRunHadWarnings = true
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        schedulerStartDate = Date()
        totalRunsCount = 0
        runWarningsCount = 0
        postedUpdatesCount = 0
        runOnce()
        scheduleTimer()
    }

    func stop() {
        isRunning = false
        schedulerStartDate = nil // Clear start date
        timerTask?.cancel()
        timerTask = nil
        nextRun = nil
        lastRunHadWarnings = false
    }

    @discardableResult
    func runNowIfIdle() -> Bool {
        if isPerformingRun { return false }
        Task { await self._runOnceAsync(kind: .manual, dryRun: false) }
        return true
    }

    func runDryIfIdle() -> Bool {
        if isPerformingRun { return false }
        Task { await self._runOnceAsync(kind: .manual, dryRun: true) }
        return true
    }
    
    func runOnce() {
        if isPerformingRun { return }
        Task { await self._runOnceAsync(kind: .scheduled, dryRun: false) }
    }

    private func scheduleTimer() {
        timerTask?.cancel()
        guard let settings else { return }
        let sec = max(60, settings.updateIntervalSec)
        
        timerTask = Task {
            while !Task.isCancelled {
                await MainActor.run { self.nextRun = Date().addingTimeInterval(sec) }
                
                do {
                    try await Task.sleep(for: .seconds(sec))
                } catch {
                    break
                }
                
                if !Task.isCancelled { await self._runOnceAsync(kind: .scheduled, dryRun: false) }
            }
        }
        lastScheduledIntervalSec = sec
    }

    private func rescheduleIfNeeded(reason: String) {
        guard isRunning, let settings else { return }
        let newSec = max(60, settings.updateIntervalSec)
        guard lastScheduledIntervalSec != newSec else { return }
        
        logger?.info("Schedule updated to \(Int(newSec/60)) min; rescheduling.")
        scheduleTimer()
    }

    private func markRunFinished() {
        lastRun = Date()
    }

    private func resetAfterRun() {
        self.isPerformingRun = false
        self.currentRunKind = self.isRunning ? .scheduled : .none
    }

    @MainActor
    private func beginRun(kind: RunKind, dryRun: Bool) {
        isPerformingRun = true
        currentRunKind = kind
        currentRunMode = dryRun ? .dry : .normal
        lastRunHadWarnings = false
        lastRunHadFatalError = false
    }

    private func formatted(_ date: Date?) -> String {
        guard let d = date else { return "—" }
        return runDateFormatter.string(from: d)
    }

    // MARK: - Run helper models

    enum DeviceSource: String { case device, item }

    struct LocatedEntry {
        let point: DevicePoint
        let source: DeviceSource
    }

    struct RunMetrics {
        let discoveredDevices: Int
        let discoveredItems: Int
        let locatedDevices: Int
        let locatedItems: Int
        let unassignedCount: Int
        let notTrackedCount: Int
        let toPostCount: Int
        let noLocationCount: Int
    }

    struct IOPhase {
        let rawBySource: [FMIPCacheFile: [[String: Any]]]
        let devicesBySource: [FMIPCacheFile: [DevicePoint]]
        let hadSuccessfulDecrypt: Bool
    }

    struct PlanPhase {
        let toPost: [DevicePoint]
        let aliasByUUID: [String: String]
        let metrics: RunMetrics
    }

    // Shared helpers to build a UUID -> DeviceSource map
    func sourceByUUIDMap(from entries: [LocatedEntry]) -> [String: DeviceSource] {
        var map: [String: DeviceSource] = [:]
        map.reserveCapacity(entries.count)
        for e in entries { map[e.point.id.normalized()] = e.source }
        return map
    }

    func sourceByUUIDMap(from devicesBySource: [FMIPCacheFile: [DevicePoint]]) -> [String: DeviceSource] {
        var map: [String: DeviceSource] = [:]
        for (file, list) in devicesBySource {
            let src: DeviceSource = (file == .devices) ? .device : .item
            for d in list { map[d.id.normalized()] = src }
        }
        return map
    }

    private func readAndParseCaches(
        candidates: [FMIPCacheFile],
        settings: SettingsStore,
        logger: LogStore
    ) async throws -> IOPhase {
        var rawBySource: [FMIPCacheFile: [[String: Any]]] = [:]
        var devicesBySource: [FMIPCacheFile: [DevicePoint]] = [:]
        var hadSuccessfulDecrypt = false

        for file in candidates {
            switch await decryptor.readEncryptedPayload(from: file, logger: logger) {
            case .success(let data):
                switch await decryptor.decryptPayload(data, logger: logger) {
                case .success(let plaintext):
                    switch decryptor.parsePlistData(plaintext) {
                    case .success(let arr):
                        rawBySource[file, default: []].append(contentsOf: arr)
                        let points = decryptor.parseDeviceArray(arr)
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
        Task { @MainActor in
            self.lastLocatedDevices = allDevices
            self.lastLocatedEntries = allEntries
        }

        return IOPhase(
            rawBySource: rawBySource,
            devicesBySource: devicesBySource,
            hadSuccessfulDecrypt: hadSuccessfulDecrypt
        )
    }

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
        settings: SettingsStore,
        logger: LogStore,
        allowAutoLearn: Bool
    ) -> PlanPhase {
        // Per-source counts
        let discoveredDevices = rawBySource[.devices]?.count ?? 0
        let discoveredItems   = rawBySource[.items]?.count ?? 0
        let locatedDevices    = devicesBySource[.devices]?.count ?? 0
        let locatedItems      = devicesBySource[.items]?.count ?? 0

        // Build a fast UUID -> alias record map once for this plan
        var aliasByUUIDLocal: [String: DeviceAlias] = [:]
        aliasByUUIDLocal.reserveCapacity(settings.aliases.count * 2)
        for a in settings.aliases {
            for u in a.knownUUIDs { aliasByUUIDLocal[u] = a }
        }

        // Build a source map once using shared helper
        let sourceMap = sourceByUUIDMap(from: devicesBySource)
        func label(for src: DeviceSource?) -> String { (src == .item) ? "Item" : "Device" }

        // No-location metric (from raw arrays) — compact guard style
        let decryptedArray = (rawBySource[.devices] ?? []) + (rawBySource[.items] ?? [])
        var noLocationCount = 0
        for raw in decryptedArray {
            let id = normalizeID(raw["baUUID"]) ?? normalizeID(raw["deviceDiscoveryId"])
            let hasValidLocation: Bool = {
                guard let loc = raw["location"] as? [String: Any],
                      loc["latitude"] as? Double != nil,
                      loc["longitude"] as? Double != nil,
                      loc["horizontalAccuracy"] as? Double != nil
                else { return false }
                return true
            }()
            if !hasValidLocation, let id {
                let name = (raw["name"] as? String) ?? ""
                logger.debug("- \(name) (\(id)) has no location")
                noLocationCount += 1
            }
        }

        // Single pass over all devices to build plan and metrics
        let allDevices = Array(devicesBySource.values.joined())
        var toPost: [DevicePoint] = []
        var aliasByUUID: [String: String] = [:]
        var unassignedCount = 0
        var notTrackedCount = 0

        for d in allDevices {
            let uuid = d.id.normalized()
            let srcLabel = label(for: sourceMap[uuid])

            if let rec = aliasByUUIDLocal[uuid] {
                // Refresh lastSeenName when we see this device
                if !d.name.isEmpty {
                    settings.updateAlias(rec.alias, addUUID: nil, removeUUID: nil, lastSeenName: d.name)
                }

                logDevice(d, source: srcLabel, alias: rec.alias, tracked: rec.tracked, logger: logger)
                if rec.tracked {
                    toPost.append(d)
                    aliasByUUID[uuid] = rec.alias
                } else {
                    notTrackedCount += 1
                }
            }
            else {
                // Attempt auto-learn by matching device name to alias.lastSeenName
                var learnedAlias: DeviceAlias? = nil
                if allowAutoLearn, !d.name.isEmpty {
                    // Find first alias whose lastSeenName matches the device name (case-insensitive)
                    if let matchIdx = settings.aliases.firstIndex(where: { ($0.lastSeenName ?? "").caseInsensitiveCompare(d.name) == .orderedSame }) {
                        let aliasKey = settings.aliases[matchIdx].alias
                        let evicted = settings.updateAliasWithCap(aliasKey, addUUID: d.id, lastSeenName: d.name)
                        // Refresh from settings to get latest tracked/uuids
                        if let updated = settings.aliases.first(where: { $0.alias == aliasKey }) {
                            learnedAlias = updated
                            aliasByUUIDLocal[d.id.normalized()] = updated
                            if !evicted.isEmpty {
                                logger.debug("Alias \"\(aliasKey)\" reached cap; evicted \(evicted.count) old UUID(s)")
                            }
                            logger.info("Auto-learned UUID \(d.id.normalized()) for alias \"\(aliasKey)\" (name match)")
                            self.learnedUUIDsCount &+= 1
                        }
                    }
                }

                if let rec = learnedAlias {
                    // Treat as assigned via learned alias
                    logDevice(d, source: srcLabel, alias: rec.alias, tracked: rec.tracked, logger: logger)
                    if rec.tracked {
                        toPost.append(d)
                        aliasByUUID[uuid] = rec.alias
                    } else {
                        notTrackedCount += 1
                    }
                } else {
                    // Still unassigned
                    logDevice(d, source: srcLabel, alias: nil, tracked: false, logger: logger)
                    unassignedCount += 1
                }
            }
        }

        let metrics = RunMetrics(
            discoveredDevices: discoveredDevices,
            discoveredItems: discoveredItems,
            locatedDevices: locatedDevices,
            locatedItems: locatedItems,
            unassignedCount: unassignedCount,
            notTrackedCount: notTrackedCount,
            toPostCount: toPost.count,
            noLocationCount: noLocationCount
        )

        return PlanPhase(toPost: toPost, aliasByUUID: aliasByUUID, metrics: metrics)
    }

    private func runPreflight(using candidates: [FMIPCacheFile],
                              settings: SettingsStore,
                              logger: LogStore,
                              dryRun: Bool) async -> Bool {
        // 1) Try enabled caches in order to ensure at least one is readable
        var preflightEncrypted: Data? = nil
        preflightLoop: for file in candidates {
            switch await decryptor.readEncryptedPayload(from: file, logger: logger) {
            case .success(let data):
                preflightEncrypted = data
                logger.debug("Pre-flight check passed: \(file.displayName) cache is readable.")
                break preflightLoop
            case .failure(let e):
                logger.error(e.localizedDescription)
                if case .fdaRequired = e {
                    return false // abort pre-flight
                } else {
                    continue // try next candidate
                }
            }
        }
        guard let preflightData = preflightEncrypted else {
            logger.error("Pre-flight failed: No enabled cache could be read.")
            return false
        }

        // 2) Key validity
        switch await decryptor.decryptPayload(preflightData, logger: logger) {
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

        // 3) Endpoint auth (normal runs only)
        if dryRun {
            logger.info("[DRY] Skipping pre-flight endpoint authentication test")
        } else {
            if settings.endpointAuth.isEmpty {
                settings.endpointAuthStatus = .notSet
            }
            do {
                try await decryptor.testEndpointAuthentication(settings: settings)
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
        }
        return true
    }

    private func _runOnceAsync(kind: RunKind, dryRun: Bool) async {
        let t0 = Date()

        await MainActor.run { self.beginRun(kind: kind, dryRun: dryRun) }
        defer {
            Task { @MainActor in
                self.markRunFinished()
                self.resetAfterRun()
                self.currentRunMode = .normal
            }
        }

        guard let settings, let logger else { return }
        await decryptor.ensureFMIPKey(logger: logger)

        if dryRun { logger.info("[DRY] Beginning run") }

        // --- Pre-flight ---
        let candidates: [FMIPCacheFile] = {
            var list: [FMIPCacheFile] = []
            if settings.enableDevices { list.append(.devices) }
            if settings.enableItems   { list.append(.items) }
            return list
        }()
        if candidates.isEmpty {
            logger.info("Both Devices and Items are disabled; nothing to do this run.")
            return
        }
        guard await runPreflight(using: candidates, settings: settings, logger: logger, dryRun: dryRun) else { return }

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

        // --- Read/decrypt/parse (post-refresh) ---
        let io: IOPhase
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
        if io.hadSuccessfulDecrypt {
            settings.fmipKeyStatus = .valid
        } else {
            logger.warn("No enabled caches produced usable data; aborting run.")
            return
        }

        // --- Build plan & log ---
        let plan = buildPlanAndLog(
            devicesBySource: io.devicesBySource,
            rawBySource: io.rawBySource,
            settings: settings,
            logger: logger,
            allowAutoLearn: (settings.autoLearnUUIDs && !dryRun)
        )
        let toPost = plan.toPost
        let aliasByUUID = plan.aliasByUUID

        // --- Plan summary (before posting) ---
        let planDiscovered = plan.metrics.discoveredDevices + plan.metrics.discoveredItems
        let planLocated    = plan.metrics.locatedDevices + plan.metrics.locatedItems
        let planToPost     = plan.metrics.toPostCount
        let planUnassigned = plan.metrics.unassignedCount
        let planNoLocation = plan.metrics.noLocationCount

        let summary = "discovered=\(planDiscovered) located=\(planLocated) \(dryRun ? "would_post" : "to_post")=\(planToPost) unassigned=\(planUnassigned)\(planNoLocation > 0 ? " no_location=\(planNoLocation)" : "")"
        logger.debug(dryRun ? "[DRY] Summary — \(summary)" : "Plan — \(summary)")
        
        let postSummary = await decryptor.post(toPost,
                                           aliasByUUID: aliasByUUID,
                                           settings: settings,
                                           logger: logger,
                                           dryRun: dryRun)
        
        if !dryRun {
            logger.debug("Result — posted=\(postSummary.successCount) auth_rejected=\(postSummary.authRejectedCount) transient=\(postSummary.transientCount)")
        }
        
        let trackedCount = planToPost
        let postedCount = postSummary.successCount
        
        // Promote/demote auth status based on real posts (never in dry run)
        if !dryRun {
            if postSummary.successCount > 0 {
                updateEndpointAuthStatus(outcome: .success, dryRun: false)
            } else if postSummary.authRejectedCount > 0 {
                updateEndpointAuthStatus(outcome: .authRejected, dryRun: false)
            } // else only transients → no change
        }

        let elapsed = Date().timeIntervalSince(t0)
        let elapsedStr = String(format: "%.2f", elapsed)

        // Metrics:
        // discovered = all potential devices (before location filter)
        // located    = devices with valid location (== devices.count)
        // to_post    = tracked aliases that will post (normal run)
        // would_post = same as to_post in dry run
        // unassigned = located with no alias
        // not_tracked= located with alias, but alias.tracked == false

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
            logger.info("Finished run — " + parts.joined(separator: " ") + " elapsed=\(elapsedStr)s")

            await MainActor.run {
                if !self.lastRunHadWarnings { self.totalRunsCount += 1 }
                self.postedUpdatesCount += postedCount
            }
        }
    }
    
    var lastRunText: String { formatted(lastRun) }
    var nextRunText: String { formatted(nextRun) }
}

