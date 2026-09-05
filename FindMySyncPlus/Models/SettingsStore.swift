import SwiftUI
import Foundation

enum LogLevel: Int, CaseIterable, Codable {
    case error = 0, warn = 1, info = 2, debug = 3
    var display: String {
        switch self {
        case .error: return "Error"
        case .warn:  return "Warn"
        case .info:  return "Info"
        case .debug: return "Debug"
        }
    }
    var emoji: String {
        switch self {
        case .error: "🛑"
        case .warn:  "⚠️"
        case .info:  "ℹ️"
        case .debug: "🐞"
        }
    }
    var color: Color {
        switch self {
        case .error: return .red
        case .warn:  return .orange
        case .info:  return .secondary
        case .debug: return .teal
        }
    }
    var accentColor: Color {
        switch self {
        case .error: return .red
        case .warn:  return .orange
        default:     return .clear
        }
    }
}

enum KeyStatus {
    case notPresent
    case present // Key exists, but has not been validated by a successful decrypt.
    case valid   // Key has been used for a successful decrypt.
    case invalid // A decrypt was attempted with this key and failed.
}

enum EndpointAuthStatus: String, Codable {
    case notSet
    case unverified
    case valid
    case invalid
}

enum TransportMode: String, CaseIterable {
    case mqtt
    case rest
}

@MainActor
final class SettingsStore: ObservableObject {
    init() {
        // Load Keychain-backed values synchronously to avoid launch-time UI flicker
        if let s = Keychain.getString(for: .endpointAuth) {
            self.endpointAuth = s
        }
        if let p = Keychain.getString(for: .mqttPassword) {
            self.mqttPassword = p
        }

        if Keychain.getData(for: .fmipSymmetricKey) != nil {
            self.fmipKeyStatus = .present
        } else {
            self.fmipKeyStatus = .notPresent
        }

        if Keychain.getData(for: .fmfKey) != nil {
            self.fmfKeyStatus = .present
        } else {
            self.fmfKeyStatus = .notPresent
        }

        if Keychain.getData(for: .localStorageKey) != nil {
            self.localStorageKeyStatus = .present
        } else {
            self.localStorageKeyStatus = .notPresent
        }

        // Every level is a standing preference except Debug, which is heavy enough to turn
        // a 5000-entry buffer over in a few hours. An app that came back up in it would
        // keep doing that for anyone who switched it on once, so a diagnostic run sets it
        // for that run.
        //
        // Nothing restored it at all until now: the sync lived in `didSet`, which does not
        // fire during initialization, so the value was written on every change and never
        // read back.
        let stored = LogLevel(rawValue: storedLogLevel) ?? .info
        self.logLevel = stored == .debug ? .info : stored

        self.loadAliasesFromStorage()

        // One-time migration: existing REST users keep REST as default transport
        if !transportModeExplicitlySet && !endpointURL.isEmpty {
            transportMode = .rest
            transportModeExplicitlySet = true
        }
    }

    func setTransportMode(_ mode: TransportMode) {
        transportMode = mode
        transportModeExplicitlySet = true
    }

    // Transport mode
    @AppStorage("transportMode") var transportMode: TransportMode = .mqtt
    @AppStorage("transportModeExplicitlySet") private var transportModeExplicitlySet: Bool = false

    // Endpoint (REST)
    @AppStorage("endpointURL") var endpointURL: String = ""

    @Published var endpointAuth: String = "" {
        didSet {
            if endpointAuth.isEmpty {
                endpointAuthStatus = .notSet
            } else if endpointAuth != oldValue {
                endpointAuthStatus = .unverified
            }
        }
    }

    // MQTT broker settings
    @AppStorage("mqttHost") var mqttHost: String = ""
    @AppStorage("mqttPort") var mqttPort: Int = 1883
    @AppStorage("mqttUseTLS") var mqttUseTLS: Bool = false
    @AppStorage("mqttUsername") var mqttUsername: String = ""
    @AppStorage("mqttTopicPrefix") var mqttTopicPrefix: String = "findmysyncplus/"

    @Published var mqttPassword: String = "" {
        didSet {
            _ = Keychain.setString(mqttPassword, for: .mqttPassword)
        }
    }

    func updateMqttPassword(_ newValue: String) {
        mqttPassword = newValue
    }

    // Interval (seconds on disk, minutes in UI)
    @AppStorage("updateIntervalSec") var updateIntervalSec: Double = 300
    @Published var fmipKeyStatus: KeyStatus = .notPresent
    @Published var fmfKeyStatus: KeyStatus = .notPresent
    @Published var localStorageKeyStatus: KeyStatus = .notPresent
    @Published var endpointAuthStatus: EndpointAuthStatus = .unverified
    @AppStorage("autoLaunchKillFindMy") var autoLaunchKillFindMy: Bool = true
    @AppStorage("autoStartSchedulerOnLaunch") var autoStartSchedulerOnLaunch: Bool = false
    @AppStorage("openMainOnLaunch") var openMainOnLaunch: Bool = true
    @AppStorage("findMyWaitSeconds") var findMyWaitSeconds: Double = 10
    @AppStorage("enableDevices") var enableDevices: Bool = true
    @AppStorage("enableItems") var enableItems: Bool = true
    @AppStorage("enableFriends") var enableFriends: Bool = false
    @AppStorage("maxUUIDsPerAlias") var maxUUIDsPerAlias: Int = 2
    @AppStorage("autoLearnUUIDs") var autoLearnUUIDs: Bool = false

    // Menu Bar options

    @AppStorage("deviceAliasesJSON") private var deviceAliasesJSON: String = "[]"

    /// Persisted, so a standing preference for Warn or Error survives a launch. **Debug
    /// does not** — see `init`.
    @AppStorage("logLevelRaw") private var storedLogLevel: Int = LogLevel.info.rawValue

    @Published var logLevel: LogLevel = .info {
        didSet {
            // Written back on every change, including the Debug-to-Info clamp at launch,
            // so what is stored and what is shown never disagree.
            if storedLogLevel != logLevel.rawValue { storedLogLevel = logLevel.rawValue }
        }
    }

    @Published var aliases: [DeviceAlias] = [] {
        didSet { saveAliasesToStorage() }
    }

    func importFMIPKey(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dict = plist as? [String: Any] else {
            throw NSError(domain: "plist", code: 1, userInfo: [NSLocalizedDescriptionKey: "Top-level is not a dictionary"])
        }
        guard let raw = try CacheDecryptor.extractSymmetricKey(from: dict) else {
            throw NSError(domain: "symmetricKey", code: 2, userInfo: [NSLocalizedDescriptionKey: "symmetricKey not found or invalid"])
        }
        guard Keychain.set(raw, for: .fmipSymmetricKey) else {
            throw NSError(domain: "Keychain", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to store key in Keychain"])
        }
        fmipKeyStatus = .present
        enableDevices = true
        enableItems = true
    }

    func importFMFKey(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dict = plist as? [String: Any] else {
            throw NSError(domain: "plist", code: 1, userInfo: [NSLocalizedDescriptionKey: "Top-level is not a dictionary"])
        }
        guard let raw = try CacheDecryptor.extractSymmetricKey(from: dict) else {
            throw NSError(domain: "symmetricKey", code: 2, userInfo: [NSLocalizedDescriptionKey: "symmetricKey not found or invalid"])
        }
        guard Keychain.set(raw, for: .fmfKey) else {
            throw NSError(domain: "Keychain", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to store FMF key in Keychain"])
        }
        fmfKeyStatus = .present
    }

    func importLocalStorageKey(from url: URL) throws {
        let raw = try Data(contentsOf: url)
        guard raw.count == 32 else {
            throw NSError(domain: "localStorageKey", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected 32-byte raw key, got \(raw.count) bytes"])
        }
        guard Keychain.set(raw, for: .localStorageKey) else {
            throw NSError(domain: "Keychain", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to store LocalStorage key in Keychain"])
        }
        localStorageKeyStatus = .present
        enableFriends = true
    }

    private func loadAliasesFromStorage() {
        // Defensive decode; never throw. Corrupt data -> reset to empty.
        let data = Data(deviceAliasesJSON.utf8)
        if data.isEmpty {
            self.aliases = []
            return
        }
        do {
            let decoded = try JSONDecoder().decode([DeviceAlias].self, from: data)
            self.aliases = decoded
        } catch {
            // Corrupt or incompatible -> reset
            self.aliases = []
        }
    }

    private func saveAliasesToStorage() {
        do {
            let data = try JSONEncoder().encode(self.aliases)
            if let s = String(data: data, encoding: .utf8) {
                self.deviceAliasesJSON = s
            }
        } catch {
            // Ignore persistence failure; keep in-memory state
        }
    }

    /// Ensure alias string is unique across current aliases (append -2, -3… if needed).
    func uniqueAlias(from base: String) -> String {
        let baseSlug = slugifyAlias(base)
        if !aliases.contains(where: { $0.alias == baseSlug }) {
            return baseSlug
        }
        // Disambiguate with incrementing suffix
        var n = 2
        while true {
            let candidate = "\(baseSlug)-\(n)"
            if !aliases.contains(where: { $0.alias == candidate }) {
                return candidate
            }
            n += 1
        }
    }

    /// Create a new alias based on a suggested name.
    /// Returns the created alias key.
    @discardableResult
    func createAlias(from suggestedName: String,
                     tracked: Bool = false,
                     initialUUID: String? = nil,
                     lastSeenName: String? = nil) -> String {
        let key = uniqueAlias(from: suggestedName)
        var list: [String] = []
        if let u = initialUUID?.normalized(), !u.isEmpty { list = [u] }
        let alias = DeviceAlias(alias: key, tracked: tracked, knownUUIDs: list, lastSeenName: lastSeenName)
        aliases.append(alias) // triggers save
        return key
    }

    /// Apply multiple lastSeenName updates in a single storage write.
    func batchUpdateLastSeenNames(_ updates: [(aliasKey: String, name: String)]) {
        guard !updates.isEmpty else { return }
        var copy = aliases
        for u in updates {
            guard let idx = copy.firstIndex(where: { $0.alias == u.aliasKey }) else { continue }
            copy[idx].lastSeenName = u.name
        }
        aliases = copy
    }

    /// Record which group each aliased child belongs to, in one write per run.
    ///
    /// Written whenever a live join is observed and read regardless of whether either
    /// device reported this cycle — the relationship belongs to the pair, not to a run,
    /// so a group still nests when it is offline. Overwriting on every observation is
    /// what makes regrouping self-correct.
    func batchUpdateParentAliases(_ updates: [(aliasKey: String, parentAlias: String)]) {
        guard !updates.isEmpty else { return }
        var copy = aliases
        var changed = false
        for u in updates {
            guard let idx = copy.firstIndex(where: { $0.alias == u.aliasKey }) else { continue }
            guard copy[idx].parentAlias != u.parentAlias else { continue }
            copy[idx].parentAlias = u.parentAlias
            changed = true
        }
        // Only write when something moved: this runs every cycle, and the value is
        // stable once learned.
        guard changed else { return }
        aliases = copy
    }

    /// One observed child-to-group join. A named type rather than a tuple because three
    /// same-typed members read as three interchangeable strings at the call site.
    struct ParentGroupUpdate {
        let aliasKey: String
        let groupID: String
        let groupName: String
    }

    /// Record the group's own identity on each aliased child, in one write per run.
    ///
    /// Distinct from `batchUpdateParentAliases`, and written under a weaker condition:
    /// that one needs *both* ends aliased, this one needs only the child to be. That is
    /// the whole point — it is what lets a header be drawn for a group the user never
    /// aliased, or whose alias they deleted, without waiting for the accessory to report.
    ///
    /// The name is refreshed on every observation so a rename in Find My propagates.
    func batchUpdateParentGroups(_ updates: [ParentGroupUpdate]) {
        guard !updates.isEmpty else { return }
        var copy = aliases
        var changed = false
        for u in updates {
            guard let idx = copy.firstIndex(where: { $0.alias == u.aliasKey }) else { continue }
            guard copy[idx].parentGroupID != u.groupID
                    || copy[idx].parentGroupName != u.groupName else { continue }
            copy[idx].parentGroupID = u.groupID
            copy[idx].parentGroupName = u.groupName
            changed = true
        }
        // Only write when something moved: this runs every cycle and the value is
        // stable once learned.
        guard changed else { return }
        aliases = copy
    }

    /// Add (or remove) a UUID to an existing alias.
    func updateAlias(_ aliasKey: String, addUUID uuid: String? = nil, removeUUID: String? = nil, lastSeenName: String? = nil) {
        guard let idx = aliases.firstIndex(where: { $0.alias == aliasKey }) else { return }
        var a = aliases[idx]
        if let u = uuid?.normalized(), !u.isEmpty {
            // move-to-front if exists, else insert at front
            if let existing = a.knownUUIDs.firstIndex(of: u) {
                a.knownUUIDs.remove(at: existing)
            }
            a.knownUUIDs.insert(u, at: 0)
            // Enforce cap (do not evict here; cap-aware API below handles eviction)
        }
        if let r = removeUUID?.normalized(), !r.isEmpty {
            a.knownUUIDs.removeAll(where: { $0 == r })
        }
        if let name = lastSeenName { a.lastSeenName = name }
        aliases[idx] = a // triggers save
    }

    /// Add a UUID and enforce the maxUUIDsPerAlias cap by evicting from the end.
    func updateAliasWithCap(_ aliasKey: String, addUUID uuid: String, lastSeenName: String?) -> [String] {
        guard let idx = aliases.firstIndex(where: { $0.alias == aliasKey }) else { return [] }
        var a = aliases[idx]
        let u = uuid.normalized()
        if let existing = a.knownUUIDs.firstIndex(of: u) {
            a.knownUUIDs.remove(at: existing)
        }
        a.knownUUIDs.insert(u, at: 0)
        if let name = lastSeenName { a.lastSeenName = name }
        var evicted: [String] = []
        // Enforce cap (default 2)
        if maxUUIDsPerAlias > 0 && a.knownUUIDs.count > maxUUIDsPerAlias {
            let kept = Array(a.knownUUIDs.prefix(maxUUIDsPerAlias))
            let removed = Array(a.knownUUIDs.dropFirst(maxUUIDsPerAlias))
            a.knownUUIDs = kept
            evicted = removed
        }
        aliases[idx] = a // triggers save
        return evicted
    }

    // MARK: - Retired dev_ids

    /// dev_ids whose retained MQTT topics still need clearing.
    ///
    /// Persisted, because an alias can be renamed or deleted while the app is
    /// disconnected, and the retained discovery config and attributes topic would
    /// otherwise sit on the broker forever — the latter holding the device's last
    /// latitude/longitude under a name the user deliberately removed.
    ///
    /// Recorded here rather than discovered from the broker: the app knows exactly
    /// which topics it published, so no ownership guess is involved. If this list
    /// is ever lost the cost is one uncleaned orphan, never a wrong deletion.
    @AppStorage("retiredDevIds") private var retiredDevIdsRaw: String = "[]"

    var retiredDevIds: [String] {
        get { (try? JSONDecoder().decode([String].self, from: Data(retiredDevIdsRaw.utf8))) ?? [] }
        set {
            let data = (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8)
            retiredDevIdsRaw = String(data: data, encoding: .utf8) ?? "[]"
        }
    }

    func retireDevId(_ devId: String) {
        var current = retiredDevIds
        guard !current.contains(devId) else { return }
        current.append(devId)
        retiredDevIds = current
    }

    /// Toggle tracking for an alias.
    func setAlias(_ aliasKey: String, tracked: Bool) {
        guard let idx = aliases.firstIndex(where: { $0.alias == aliasKey }) else { return }
        var a = aliases[idx]
        a.tracked = tracked
        aliases[idx] = a // triggers save
        // Untracking stops publishing but leaves both retained topics behind, exactly
        // as a delete does. Re-tracking filters the tombstone out again, since the
        // devId is live in the next publish cycle.
        if !tracked { retireDevId(DeviceAlias.entityID(for: aliasKey)) }
    }

    /// Rename an alias (WARNING: changes HA entity id). Ensures uniqueness.
    func renameAlias(from oldKey: String, to newRaw: String) {
        guard let idx = aliases.firstIndex(where: { $0.alias == oldKey }) else { return }
        let newKey = uniqueAlias(from: newRaw)
        guard newKey != oldKey else { return }
        var a = aliases[idx]
        a.alias = newKey
        aliases[idx] = a // triggers save
        retireDevId(DeviceAlias.entityID(for: oldKey))
    }

    /// Remove an alias. Its retained MQTT topics are cleared on the next publish.
    func deleteAlias(_ aliasKey: String) {
        guard aliases.contains(where: { $0.alias == aliasKey }) else { return }
        aliases.removeAll(where: { $0.alias == aliasKey })
        retireDevId(DeviceAlias.entityID(for: aliasKey))
    }

    func updateEndpointAuth(_ newValue: String) {
        endpointAuth = newValue
        _ = Keychain.setString(newValue, for: .endpointAuth)
    }
}
