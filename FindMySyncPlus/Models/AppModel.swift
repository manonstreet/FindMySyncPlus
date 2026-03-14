import Foundation
import Combine
import SwiftUI

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

    let syncEngine = SyncEngine()
    private var timerTask: Task<Void, Never>?
    private weak var settings: SettingsStore?
    private weak var logger: LogStore?

    private var cancellables = Set<AnyCancellable>()
    private var lastScheduledIntervalSec: Double? = nil

    override init() {
        super.init()
    }

    func bind(settings: SettingsStore, logger: LogStore) {
        self.settings = settings
        self.logger = logger
        syncEngine.bind(settings: settings, logger: logger, app: self)
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
            logger.warn("Auth Test: header not set.")
            return .badConfig("Auth header not set")
        }

        do {
            try await HAClient.testEndpointAuthentication(settings: settings)
            syncEngine.updateEndpointAuthStatus(outcome: .success, dryRun: false)
            logger.info("Auth Test: success")
            return .success
        } catch let auth as AuthError {
            switch auth {
            case .authRejected:
                syncEngine.updateEndpointAuthStatus(outcome: .authRejected, dryRun: false)
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

    // MARK: - MQTT test

    func triggerManualMQTTTestAsync() async -> (Bool, String) {
        guard !isPerformingRun else { return (false, "Busy") }
        guard let settings else { return (false, "Unavailable") }
        return await syncEngine.mqtt.testConnection(settings: settings)
    }

    // MARK: - Scheduler

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

                if !Task.isCancelled { await self.syncEngine.run(kind: .scheduled, dryRun: false) }
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
