import Foundation

// MARK: - The sync status entity
extension SyncEngine {

    /// One run's inputs to the status entity — a struct rather than four more parameters on
    /// a call that already takes settings, logger and app model.
    struct StatusRun {
        let startedAt: Date
        let metrics: RunMetrics
        let postSummary: PostSummary
        let dryRun: Bool
        /// Whether this run relaunched Find My, and when the cache it read was last written.
        /// Carried together: the cache advances because we launch Find My, so "it did not
        /// move" is only a finding once you know we asked.
        let findMyLaunched: Bool
        let cacheWritten: Date?
    }

    /// MQTT only and never on a dry run: a dry run publishes nothing, and a status entity
    /// claiming a sync had just happened would be the one thing it did publish.
    nonisolated static func publishesStatus(dryRun: Bool, transport: TransportMode) -> Bool {
        !dryRun && transport == .mqtt
    }

    /// What the report needs from outside the run: the app's state at publish time.
    struct StatusContext {
        let version: String
        let sleptDuringRun: Bool
        let keys: String
        let fullDiskAccess: Bool
        let lastError: String?
        /// Unassigned identities the user has not been shown in Tracking yet. Gathered here
        /// with the rest of the app's state, because it reads the seen set and the aliases,
        /// which the run's own metrics know nothing about.
        let newUnassigned: Int
    }

    /// One run's report, from the run's own numbers and the app state handed in.
    nonisolated static func statusReport(for run: StatusRun,
                                         context: StatusContext,
                                         now: Date = Date()) -> SyncStatusReport {
        let m = run.metrics
        return SyncStatusReport(
            version: context.version,
            runSeconds: now.timeIntervalSince(run.startedAt),
            discovered: m.discoveredDevices + m.discoveredItems + m.discoveredFriends,
            located: m.locatedDevices + m.locatedItems + m.locatedFriends,
            tracked: m.toPostCount,
            published: run.postSummary.successCount,
            skippedUnchanged: run.postSummary.skippedUnchangedCount,
            noLocation: m.noLocationCount,
            unassigned: m.unassignedCount,
            newUnassigned: context.newUnassigned,
            sleptDuringRun: context.sleptDuringRun,
            findMyLaunched: run.findMyLaunched,
            cacheWritten: run.cacheWritten,
            keys: context.keys,
            fullDiskAccess: context.fullDiskAccess,
            lastError: context.lastError
        )
    }

    /// Publish the sync status entity for this run.
    func publishStatusEntity(_ run: StatusRun,
                             settings: SettingsStore,
                             logger: LogStore,
                             app: AppModel) {
        guard Self.publishesStatus(dryRun: run.dryRun, transport: settings.transportMode) else { return }

        // A run that reached here without a fatal error is a successful sync, including one
        // that published nothing because every position was unchanged.
        if !app.lastRunHadFatalError { app.markSyncSucceeded() }

        let installedVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "—"

        let context = StatusContext(
            version: installedVersion,
            sleptDuringRun: app.sleptDuring(runStartedAt: run.startedAt),
            keys: SyncStatusReport.keysDescription(fmip: settings.fmipKeyStatus,
                                                   fmf: settings.fmfKeyStatus,
                                                   localStorage: settings.localStorageKeyStatus),
            fullDiskAccess: !logger.needsFullDiskAccess,
            lastError: app.lastErrorMessage,
            newUnassigned: UnassignedPartition.newSinceSeen(
                entries: app.lastLocatedEntries,
                knownUUIDs: Set(settings.aliases.flatMap { $0.knownUUIDs }),
                seen: Set(settings.seenUnassigned)).count)
        let report = Self.statusReport(for: run, context: context)

        mqtt.publishStatus(report,
                           lastSuccessfulSync: app.lastSuccessfulSync,
                           prefix: settings.mqttTopicPrefix,
                           iso: ISO8601DateFormatter())

        // The update entity, from the same run. `nil` whenever no check has answered, which
        // Home Assistant reads as unknown — a demo session never starts the updater, so that
        // is what every harness run publishes.
        mqtt.publishUpdateState(
            installed: installedVersion,
            latest: updates.flatMap {
                SparkleUpdater.latestVersion(for: $0.state, installed: installedVersion)
            },
            prefix: settings.mqttTopicPrefix)
    }
}
