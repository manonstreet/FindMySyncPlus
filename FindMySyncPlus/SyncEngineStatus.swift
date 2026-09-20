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

    /// Publish the sync status entity for this run. MQTT only and never on a dry run: a
    /// dry run publishes nothing, and a status entity claiming a sync had just happened would
    /// be the one thing it did publish.
    func publishStatusEntity(_ run: StatusRun,
                             settings: SettingsStore,
                             logger: LogStore,
                             app: AppModel) {
        guard !run.dryRun, settings.transportMode == .mqtt else { return }

        // A run that reached here without a fatal error is a successful sync, including one
        // that published nothing because every position was unchanged.
        if !app.lastRunHadFatalError { app.markSyncSucceeded() }

        let m = run.metrics
        let report = SyncStatusReport(
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String ?? "—",
            runSeconds: Date().timeIntervalSince(run.startedAt),
            discovered: m.discoveredDevices + m.discoveredItems + m.discoveredFriends,
            located: m.locatedDevices + m.locatedItems + m.locatedFriends,
            tracked: m.toPostCount,
            published: run.postSummary.successCount,
            skippedUnchanged: run.postSummary.skippedUnchangedCount,
            noLocation: m.noLocationCount,
            unassigned: m.unassignedCount,
            sleptDuringRun: app.sleptDuring(runStartedAt: run.startedAt),
            findMyLaunched: run.findMyLaunched,
            cacheWritten: run.cacheWritten,
            keys: SyncStatusReport.keysDescription(fmip: settings.fmipKeyStatus,
                                                   fmf: settings.fmfKeyStatus,
                                                   localStorage: settings.localStorageKeyStatus),
            fullDiskAccess: !logger.needsFullDiskAccess,
            lastError: app.lastErrorMessage
        )

        mqtt.publishStatus(report,
                           lastSuccessfulSync: app.lastSuccessfulSync,
                           prefix: settings.mqttTopicPrefix,
                           iso: ISO8601DateFormatter())
    }
}
