import Foundation
import Combine
import SwiftUI
import AppKit

private let runDateFormatter: DateFormatter = {
    let df = DateFormatter()
    df.dateStyle = .short
    df.timeStyle = .medium
    return df
}()

@MainActor
final class AppModel: NSObject, ObservableObject {

    enum RunMode: String { case normal, dry }
    @Published var currentRunMode: RunMode = .normal
    @Published var isPerformingRun: Bool = false
    @Published var currentRunKind: RunKind = .none
    @Published var isRunning = false
    @Published private(set) var lastRun: Date?
    /// The last run that completed its publish phase without a fatal error.
    ///
    /// Distinct from `lastRun`, which advances for any run at all. This is what the
    /// status entity carries as its state, and a run that failed must leave it alone —
    /// a failure is exactly when someone needs to see how long ago the last good one
    /// was. A run that published nothing because every position was unchanged is a
    /// success, not a failure.
    @Published private(set) var lastSuccessfulSync: Date?
    @Published private(set) var nextRun: Date?
    @Published private(set) var lastRunHadFatalError: Bool = false
    @Published var lastRunHadWarnings: Bool = false
    @Published private(set) var runWarningsCount: Int = 0
    @Published var schedulerStartDate: Date? = nil
    @Published var totalRunsCount: Int = 0
    @Published var postedUpdatesCount: Int = 0
    @Published var learnedUUIDsCount: Int = 0
    /// What the last run found that nobody has aliased. Run state, so it belongs with the
    /// counters here and on Home's Statistics card — it changes with no configuration
    /// touched. Written by every run, a dry one included.
    ///
    /// `resetCounters` leaves it alone. Runs, Warning Runs and Posts are tallies and zeroing
    /// them means something; this is the last run's finding, and a zero here would claim
    /// there is nothing to assign until the next run says otherwise.
    @Published var unassignedCount: Int = 0
    @Published var lastLocatedDevices: [DevicePoint] = []
    @Published var lastLocatedEntries: [LocatedEntry] = []

    /// Mirrors `syncEngine.mqtt.connectionState` so views can observe it.
    ///
    /// `connectionState` is `@Published` on the MQTT client, but that is a *nested*
    /// ObservableObject: SwiftUI observes `AppModel`, and a nested object's changes
    /// do not propagate to the parent. A view reading
    /// `app.syncEngine.mqtt.connectionState` therefore re-evaluates only when
    /// something unrelated republishes AppModel, and shows a stale value in the
    /// meantime — which is why Tracking's re-register button could sit
    /// greyed out while MQTT was connected.
    @Published private(set) var mqttConnected: Bool = false

    let syncEngine = SyncEngine()
    private var timerTask: Task<Void, Never>?
    private var idleDisconnectTask: Task<Void, Never>?
    private weak var settings: SettingsStore?
    private weak var logger: LogStore?

    private var cancellables = Set<AnyCancellable>()
    private var lastScheduledIntervalSec: Double? = nil

    private var sleepObservers: [NSObjectProtocol] = []
    /// Set on `willSleep`, cleared on `didWake`. Non-nil means we have seen a sleep with no
    /// matching wake.
    private var sleepStartedAt: Date?
    /// The most recent `willSleep`, kept after the wake clears `sleepStartedAt`, so a run
    /// that a sleep landed inside can still say so once it finishes.
    private var lastSleepAt: Date?
    /// The trigger setting as last applied, so the watcher acts on changes only.
    private var appliedRefreshTrigger = false
    /// When a refresh was last started from an MQTT trigger, for the debounce floor.
    private var lastTriggeredRunAt: Date?

    /// The message behind the most recent fatal error, or `nil` if the last run was clean.
    ///
    /// The status entity publishes it: `last_error` in Home Assistant is the difference
    /// between a user seeing what went wrong and filing a log line nobody can act on.
    @Published private(set) var lastErrorMessage: String?

    override init() {
        super.init()
    }

    func bind(settings: SettingsStore, logger: LogStore) {
        self.settings = settings
        self.logger = logger
        syncEngine.bind(settings: settings, logger: logger, app: self)
        logger.minimumLevel = settings.logLevel
        // The client decides that a genuine request arrived; this object decides whether a
        // run may start, which is state only it holds.
        syncEngine.mqtt.onRefreshRequested = { [weak self] in self?.handleRefreshRequest() }
        // Seeded from what is already stored, so the watcher below reports changes rather
        // than announcing the launch value as one.
        appliedRefreshTrigger = settings.enableRefreshTrigger
        observeSleepWake()
        settings.objectWillChange
            .map { settings.updateIntervalSec }
            .removeDuplicates()
            .debounce(for: .milliseconds(1000), scheduler: DispatchQueue.main)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rescheduleIfNeeded(reason: "Interval changed") }
            .store(in: &cancellables)
        // Same shape as the interval watcher above, and for the same reason:
        // `objectWillChange` fires before the value settles, so the debounce is what makes
        // the read correct. Without this the trigger setting took effect only at the next
        // connection, which reads as the feature not working.
        settings.objectWillChange
            .map { settings.enableRefreshTrigger }
            .removeDuplicates()
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in self?.applyRefreshTriggerSetting(enabled) }
            .store(in: &cancellables)
        settings.$logLevel
            .sink { [weak self] level in self?.logger?.minimumLevel = level }
            .store(in: &cancellables)
        // Republish the MQTT client's connection state as our own, so views can
        // observe it. Without this a view reading it through `syncEngine.mqtt`
        // never re-renders when the connection comes up or drops.
        syncEngine.mqtt.$connectionState
            .map { $0 == .connected }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] connected in self?.mqttConnected = connected }
            .store(in: &cancellables)
        logger.errorSignal
            .receive(on: RunLoop.main)
            .sink { [weak self] message in self?.handleFatalError(message) }
            .store(in: &cancellables)
        logger.warningSignal
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.handleWarnings() }
            .store(in: &cancellables)
        Publishers.CombineLatest3($isRunning, $isPerformingRun, $lastRunHadFatalError)
            .receive(on: RunLoop.main) // keep this
            .sink { running, _, fatal in
                Task { @MainActor in
                    let state: DockStatusOverlay.State = fatal ? .error : (running ? .running : .stopped)
                    DockStatusOverlay.shared.update(for: state)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Key invalidation (forwarded to SyncEngine)

    func invalidateCacheDecryptorKey() {
        syncEngine.invalidateCacheDecryptorKey()
    }

    func invalidateLocalStorageKey() {
        syncEngine.invalidateLocalStorageKey()
    }

    func invalidateFMFKey() {
        syncEngine.invalidateFMFKey()
    }

    // MARK: - Auth test

    @MainActor
    func triggerManualAuthTestAsync() async -> AuthStatusOutcome {
        guard !isPerformingRun else { return .transient("Busy") }
        guard let settings, let logger else { return .transient("Unavailable") }

        if settings.endpointAuth.isEmpty {
            settings.endpointAuthStatus = .notSet
            logger.warn("REST Test: header not set.")
            return .badConfig("Auth header not set")
        }

        do {
            try await syncEngine.rest.testEndpointAuthentication(settings: settings)
            syncEngine.updateEndpointAuthStatus(outcome: .success, dryRun: false)
            logger.info("REST Test: success")
            return .success
        } catch let auth as AuthError {
            switch auth {
            case .authRejected:
                syncEngine.updateEndpointAuthStatus(outcome: .authRejected, dryRun: false)
                logger.error("REST Test: \(auth.localizedDescription)")
                return .authRejected
            case .requestFailed(let code) where (500...599).contains(code):
                logger.warn("REST Test: \(auth.localizedDescription)")
                return .transient("HTTP \(code)")
            case .networkError:
                logger.warn("REST Test: \(auth.localizedDescription)")
                return .transient("Network error")
            case .invalidURL(let reason):
                logger.warn(reason)
                return .badConfig(reason)
            default:
                logger.warn("REST Test: \(auth.localizedDescription)")
                return .transient(auth.localizedDescription)
            }
        } catch {
            logger.warn("REST Test: \(error.localizedDescription)")
            return .transient(error.localizedDescription)
        }
    }

    // MARK: - MQTT test

    // MARK: - On-demand MQTT for user actions

    /// How long a connection opened for a user action is held once the scheduler is
    /// not running. Only ever applies in that case: while the scheduler is on it
    /// owns the connection and this never fires.
    nonisolated static let idleDisconnectSeconds: TimeInterval = 300

    /// Connect if we are not already, for a user-initiated action.
    ///
    /// The scheduler owns the steady-state connection, so with it stopped there is
    /// nothing to publish through — which made every MQTT-dependent action silently
    /// do nothing. A deliberate action may also preempt a pending backoff: the
    /// single-owner rule exists to stop two *automatic* drivers fighting, and a
    /// person waiting on a button is not one of those.
    /// Deliberately silent on failure: what "not reachable" *means* differs by
    /// caller. A re-registration did not happen; a rename did happen and only its
    /// cleanup is deferred. Reporting "action not applied" for both told renaming
    /// users their rename had failed, which was untrue.
    private func connectForUserAction() async -> Bool {
        guard let settings, settings.transportMode == .mqtt else { return false }
        return await syncEngine.mqtt.ensureConnected(settings: settings)
    }

    /// Release a connection opened for a user action, once it has been idle.
    ///
    /// Cancelled and rescheduled on each action. Never armed while the scheduler is
    /// running, because then the connection is not ours to close.
    private func scheduleIdleDisconnect() {
        idleDisconnectTask?.cancel()
        guard !isRunning else { idleDisconnectTask = nil; return }
        idleDisconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.idleDisconnectSeconds))
            guard !Task.isCancelled, let self, !self.isRunning else { return }
            self.syncEngine.mqtt.disconnect()
            self.logger?.info("MQTT: disconnected after idle — scheduler is not running")
        }
    }

    /// Clear the entities of aliases that were renamed, deleted or untracked, now.
    ///
    /// Otherwise the old entity lingers in Home Assistant until the next sync — up
    /// to a full interval after the user changed it, which reads as a bug.
    /// - Returns: `false` only when there was work to do and the broker could not
    ///   be reached. Nothing pending is a success, not a failure — the caller must
    ///   not raise an alert for an action that needed no publishing.
    @discardableResult
    func publishPendingRetirements() async -> Bool {
        guard let settings, settings.transportMode == .mqtt else { return true }
        guard !settings.retiredDevIds.isEmpty else { return true }
        guard await connectForUserAction() else {
            // A warning, not info: nothing was lost and the change stands, but the
            // user is looking at Home Assistant wondering why the old entity is
            // still there, and this is the only thing that answers them.
            let pending = settings.retiredDevIds.joined(separator: ", ")
            logger?.warn("MQTT: broker not reachable — \(pending) will be removed from "
                         + "Home Assistant on the next successful sync")
            return false
        }

        // Live means "still configured", not "seen this cycle" — an alias that simply
        // was not located this run is not dead.
        let live = Set(settings.aliases.filter(\.tracked).map { DeviceAlias.entityID(for: $0.alias) })
        let cleared = syncEngine.mqtt.flushRetirements(retired: settings.retiredDevIds,
                                                       liveDevIds: live,
                                                       prefix: settings.mqttTopicPrefix)
        for devId in cleared {
            logger?.info("MQTT: cleared retained topics for retired \(devId)")
        }
        if !cleared.isEmpty {
            let done = Set(cleared)
            settings.retiredDevIds = settings.retiredDevIds.filter { !done.contains($0) }
        }
        scheduleIdleDisconnect()
        return true
    }

    /// Recreate one alias's Home Assistant entity so its ID follows the alias.
    ///
    /// Destructive: the existing registry entry is removed, along with any rename,
    /// icon or area set in HA. Call only from a confirmed user action.
    func reRegisterEntity(alias: String) async -> Bool {
        guard let settings, let logger else { return false }
        guard await connectForUserAction() else {
            logger.warn("MQTT: broker not reachable — \(alias) was not re-created")
            return false
        }

        let devId = DeviceAlias.entityID(for: alias)
        let displayName = settings.aliases.first(where: { $0.alias == alias })?.lastSeenName ?? alias
        let ok = await syncEngine.mqtt.reRegister(devId: devId,
                                                  displayName: displayName,
                                                  settings: settings,
                                                  logger: logger)
        scheduleIdleDisconnect()
        return ok
    }

    func triggerManualMQTTTestAsync() async -> (Bool, String) {
        guard !isPerformingRun else { return (false, "Busy") }
        guard let settings, let logger else { return (false, "Unavailable") }
        let (ok, msg) = await syncEngine.mqtt.testConnection(settings: settings)
        if ok {
            logger.info("MQTT Test: connected to \(settings.mqttHost):\(settings.mqttPort)")
        } else {
            logger.error("MQTT Test: \(msg)")
        }
        return (ok, msg)
    }

    // MARK: - Scheduler

    // Sleep is observed and reported, and changes no behavior.
    //
    // The scheduler used to stop on `willSleep`. That was right for the laptop it was
    // built for and wrong everywhere else: it stopped an always-on VM whose guest sleeps
    // on idle, it suppressed genuinely fresh data — a suspended Mac updates its cache
    // *partially*, so some records really do advance — and it reset the Statistics on
    // every wake. What replaces it is `slept_during_run` on the status entity: a run of
    // 961 seconds looks broken on its own and is not, and passing the signal through lets
    // the user draw that conclusion instead of us deciding for them.
    //
    // Republishing the same position through a sleep is the complaint underneath, and
    // that is what skipping repeated locations answers.
    private func observeSleepWake() {
        guard sleepObservers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            observe(workspace, NSWorkspace.willSleepNotification) { [weak self] in self?.noteSleep() },
            observe(workspace, NSWorkspace.didWakeNotification) { [weak self] in self?.noteWake() }
        ]
    }

    private func observe(_ center: NotificationCenter,
                         _ name: Notification.Name,
                         handler: @escaping @MainActor () -> Void) -> NSObjectProtocol {
        center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }

    private func noteSleep() {
        let now = Date()
        sleepStartedAt = now
        lastSleepAt = now
        logger?.info("System going to sleep")
    }

    private func noteWake() {
        // No recorded sleep means the pair did not arrive in the order this assumes, so say
        // nothing about how long rather than inventing a duration.
        let slept = sleepStartedAt.map { " after \(Int(Date().timeIntervalSince($0) / 60))m" } ?? ""
        sleepStartedAt = nil
        logger?.info("System woke\(slept)")
    }

    /// Whether a sleep landed inside a run that began at `runStartedAt`.
    ///
    /// Reported rather than acted on. Measured on the machine behind #28: runs of 909,
    /// 961 and 965 seconds, and a 2-minute timer deferred to roughly 15 minutes. Those
    /// are the numbers a support thread starts from, and this is what answers it.
    func sleptDuring(runStartedAt: Date) -> Bool {
        guard let lastSleepAt else { return false }
        return lastSleepAt >= runStartedAt
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        schedulerStartDate = Date()
        totalRunsCount = 0
        runWarningsCount = 0
        postedUpdatesCount = 0
        if let settings, settings.transportMode == .mqtt {
            syncEngine.mqtt.connect(settings: settings)
        }
        runOnce()
        scheduleTimer()
    }

    func stop() {
        isRunning = false
        schedulerStartDate = nil
        timerTask?.cancel()
        timerTask = nil
        nextRun = nil
        lastRunHadWarnings = false
        syncEngine.mqtt.disconnect()
    }

    @discardableResult
    func runNowIfIdle() -> Bool {
        if isPerformingRun {
            // Was a silent `return false`: the button did nothing and the log said
            // nothing, which is indistinguishable from the button being broken.
            logger?.info("Run Now ignored — a run is already in progress")
            return false
        }
        Task { await syncEngine.run(kind: .manual, dryRun: false) }
        return true
    }

    // MARK: - Refresh trigger

    /// A triggered refresh within this many seconds of the last one is dropped, so a
    /// Home Assistant automation loop cannot hammer Find My's kill/launch cycle.
    nonisolated static let triggerMinimumIntervalSeconds: TimeInterval = 60

    /// What to do with a refresh request. Separated so the two drop reasons can be
    /// asserted on: they are different failures and must never share a log line.
    enum TriggerOutcome: Equatable {
        case run
        case droppedBusy
        case droppedTooSoon
    }

    /// Drop rather than queue. A refresh already in flight means the fresh data is on
    /// its way regardless, so a queued second run would only relaunch Find My again for
    /// data it already has.
    nonisolated static func triggerOutcome(isPerformingRun: Bool,
                                           lastTriggeredAt: Date?,
                                           now: Date) -> TriggerOutcome {
        if isPerformingRun { return .droppedBusy }
        if let lastTriggeredAt,
           now.timeIntervalSince(lastTriggeredAt) < triggerMinimumIntervalSeconds {
            return .droppedTooSoon
        }
        return .run
    }

    /// Subscribe or unsubscribe, and publish or clear the button, the moment the setting
    /// changes — rather than leaving it until the next connection.
    private func applyRefreshTriggerSetting(_ enabled: Bool) {
        // `removeDuplicates()` lets the first emission through, having nothing to compare
        // it against — so every launch applied the stored value as though the user had
        // just set it, unsubscribing from a topic never subscribed to and logging that it
        // had. Only a genuine change is worth acting on.
        guard enabled != appliedRefreshTrigger else { return }
        appliedRefreshTrigger = enabled
        guard let settings, settings.transportMode == .mqtt else { return }
        syncEngine.mqtt.applyRefreshTriggerSetting(enabled: enabled,
                                                   prefix: settings.mqttTopicPrefix)
    }

    private func handleRefreshRequest() {
        switch Self.triggerOutcome(isPerformingRun: isPerformingRun,
                                   lastTriggeredAt: lastTriggeredRunAt,
                                   now: Date()) {
        case .droppedBusy:
            logger?.info("Refresh trigger ignored — a run is already in progress")
        case .droppedTooSoon:
            logger?.info("Refresh trigger ignored — less than "
                         + "\(Int(Self.triggerMinimumIntervalSeconds))s since the last one")
        case .run:
            lastTriggeredRunAt = Date()
            Task { await syncEngine.run(kind: .triggered, dryRun: false) }
        }
    }

    func runDryIfIdle() -> Bool {
        if isPerformingRun { return false }
        Task { await syncEngine.run(kind: .manual, dryRun: true) }
        return true
    }

    func runOnce() {
        if isPerformingRun { return }
        Task { await syncEngine.run(kind: .scheduled, dryRun: false) }
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

                if !Task.isCancelled {
                    if self.sleepStartedAt != nil {
                        // Ordinary now that the scheduler no longer stops on `willSleep`:
                        // macOS defers the timer and services it during a dark wake. Kept
                        // at `.debug` because it explains an odd-looking gap in the log,
                        // and never at `.warn` — a warning here would mark every such run
                        // as having had one.
                        self.logger?.debug("Scheduled run firing while the system is asleep")
                    }
                    await self.syncEngine.run(kind: .scheduled, dryRun: false)
                }
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

    // MARK: - Run lifecycle (called by SyncEngine)

    func beginRun(kind: RunKind, dryRun: Bool) {
        isPerformingRun = true
        currentRunKind = kind
        currentRunMode = dryRun ? .dry : .normal
        lastRunHadWarnings = false
        lastRunHadFatalError = false
        lastErrorMessage = nil
    }

    func markRunFinished() {
        lastRun = Date()
    }

    func markSyncSucceeded(at date: Date = Date()) {
        lastSuccessfulSync = date
    }

    func resetAfterRun() {
        self.isPerformingRun = false
        self.currentRunKind = self.isRunning ? .scheduled : .none
        // Inert unless `demoRenderExport` is set. Renders the screens and quits, so a demo
        // session against a fixture shape is headless end to end.
        if let settings, let logger {
            ViewSnapshotExport.exportIfRequested(app: self, settings: settings, logger: logger)
        }
    }

    // MARK: - Error/warning handlers

    private func handleFatalError(_ message: String) {
        stop()
        self.lastRunHadFatalError = true
        self.lastErrorMessage = message
    }

    private func handleWarnings() {
        if lastRunHadWarnings == false { runWarningsCount &+= 1 }
        self.lastRunHadWarnings = true
    }

    // MARK: - Counters

    func resetCounters() {
        totalRunsCount = 0
        runWarningsCount = 0
        postedUpdatesCount = 0
        learnedUUIDsCount = 0
    }

    // MARK: - Source helpers

    func sourceByUUIDMap(from entries: [LocatedEntry]) -> [String: DeviceSource] {
        var map: [String: DeviceSource] = [:]
        map.reserveCapacity(entries.count)
        for e in entries { map[e.point.id.normalized()] = e.source }
        return map
    }

    // MARK: - Display helpers

    private func formatted(_ date: Date?) -> String {
        guard let d = date else { return "—" }
        return runDateFormatter.string(from: d)
    }

    var lastRunText: String { formatted(lastRun) }
    var nextRunText: String { formatted(nextRun) }

    var statusText: String {
        if lastRunHadFatalError { return "Error" }
        if isPerformingRun {
            if currentRunMode == .dry { return "Running (dry)" }
            return "Running (\(currentRunKind.rawValue))"
        }
        if !isRunning { return "Stopped" }
        if lastRunHadWarnings { return "Running (with warnings)" }
        return "Running (Idle)"
    }

    var statusColor: Color {
        if lastRunHadFatalError { return .red }
        if isPerformingRun { return .green }
        if lastRunHadWarnings { return .orange }
        if isRunning { return .green }
        return .secondary
    }
}
