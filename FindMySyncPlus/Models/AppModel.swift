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
    @Published private(set) var nextRun: Date?
    @Published private(set) var lastRunHadFatalError: Bool = false
    @Published var lastRunHadWarnings: Bool = false
    @Published private(set) var runWarningsCount: Int = 0
    @Published var schedulerStartDate: Date? = nil
    @Published var totalRunsCount: Int = 0
    @Published var postedUpdatesCount: Int = 0
    @Published var learnedUUIDsCount: Int = 0
    @Published var lastLocatedDevices: [DevicePoint] = []
    @Published var lastLocatedEntries: [LocatedEntry] = []

    /// Mirrors `syncEngine.mqtt.connectionState` so views can observe it.
    ///
    /// `connectionState` is `@Published` on the MQTT client, but that is a *nested*
    /// ObservableObject: SwiftUI observes `AppModel`, and a nested object's changes
    /// do not propagate to the parent. A view reading
    /// `app.syncEngine.mqtt.connectionState` therefore re-evaluates only when
    /// something unrelated republishes AppModel, and shows a stale value in the
    /// meantime — which is why Device Manager's re-register button could sit
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
    /// Only restart on wake what we stopped on sleep — a scheduler the user stopped stays
    /// stopped.
    private var pausedBySleep = false

    override init() {
        super.init()
    }

    func bind(settings: SettingsStore, logger: LogStore) {
        self.settings = settings
        self.logger = logger
        syncEngine.bind(settings: settings, logger: logger, app: self)
        logger.minimumLevel = settings.logLevel
        observeSleepWake()
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
            .sink { [weak self] _ in self?.handleFatalError() }
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

    // A sleeping Mac defers our timer to roughly 15 minutes and services it during dark
    // wakes, so runs continue and publish positions nobody is refreshing. Measured on two
    // machines; `sleep-suspension.md` §5a.
    //
    // Dark wakes post no `didWake`, which is what makes stopping on `willSleep` safe: we
    // stay stopped until the machine genuinely wakes.
    private func observeSleepWake() {
        guard sleepObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let register = { (name: Notification.Name, handler: @escaping @MainActor () -> Void) in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handler() }
            }
        }
        sleepObservers = [
            register(NSWorkspace.willSleepNotification) { [weak self] in self?.noteSleep() },
            register(NSWorkspace.didWakeNotification) { [weak self] in self?.noteWake() }
        ]
    }

    private func noteSleep() {
        sleepStartedAt = Date()
        guard isRunning else {
            logger?.info("System going to sleep")
            return
        }
        pausedBySleep = true
        // Logged before `stop()` so the reason precedes the disconnect it causes. An
        // in-flight run is left to finish — a sleep landing mid-run does not stop that run
        // completing, and cancelling the timer only prevents the next one.
        logger?.info("System going to sleep — stopping the scheduler")
        stop()
    }

    private func noteWake() {
        // No recorded sleep means the pair did not arrive in the order this assumes, so say
        // nothing about how long rather than inventing a duration.
        let slept = sleepStartedAt.map { " after \(Int(Date().timeIntervalSince($0) / 60))m" } ?? ""
        sleepStartedAt = nil
        guard pausedBySleep else {
            logger?.info("System woke\(slept)")
            return
        }
        pausedBySleep = false
        logger?.info("System woke\(slept) — starting the scheduler")
        start()
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
        if isPerformingRun { return false }
        Task { await syncEngine.run(kind: .manual, dryRun: false) }
        return true
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
                        // Should be unreachable: the scheduler is stopped on `willSleep`.
                        // If this appears, the pause did not hold. `.warn` rather than
                        // `.error` — an `.error` would stop the scheduler outright.
                        self.logger?.warn("Run fired while the system is believed asleep")
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
    }

    func markRunFinished() {
        lastRun = Date()
    }

    func resetAfterRun() {
        self.isPerformingRun = false
        self.currentRunKind = self.isRunning ? .scheduled : .none
    }

    // MARK: - Error/warning handlers

    private func handleFatalError() {
        stop()
        self.lastRunHadFatalError = true
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
