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

@MainActor
final class SettingsStore: ObservableObject {
    init() {
        // Load Keychain-backed values synchronously to avoid launch-time UI flicker
        if let s = Keychain.getString(for: .endpointAuth) {
            self.endpointAuth = s
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

        self.loadAliasesFromStorage()
    }

    // Endpoint
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

    // Log level
    @AppStorage("logLevelRaw") var logLevelRaw: Int = LogLevel.info.rawValue {
        didSet {
            let newLevel = LogLevel(rawValue: logLevelRaw) ?? .info
            if logLevel != newLevel { logLevel = newLevel }
        }
    }

    @Published var logLevel: LogLevel = .info {
        didSet {
            let raw = logLevel.rawValue
            if logLevelRaw != raw { logLevelRaw = raw }
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
        guard let raw = try Decryptor.extractSymmetricKey(from: dict) else {
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
        guard let raw = try Decryptor.extractSymmetricKey(from: dict) else {
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

    /// Toggle tracking for an alias.
    func setAlias(_ aliasKey: String, tracked: Bool) {
        guard let idx = aliases.firstIndex(where: { $0.alias == aliasKey }) else { return }
        var a = aliases[idx]
        a.tracked = tracked
        aliases[idx] = a // triggers save
    }

    /// Rename an alias (WARNING: changes HA entity id). Ensures uniqueness.
    func renameAlias(from oldKey: String, to newRaw: String) {
        guard let idx = aliases.firstIndex(where: { $0.alias == oldKey }) else { return }
        let newKey = uniqueAlias(from: newRaw)
        var a = aliases[idx]
        a.alias = newKey
        aliases[idx] = a // triggers save
    }

    /// Remove an alias (does not delete any HA entity; user should clean up if desired).
    func deleteAlias(_ aliasKey: String) {
        aliases.removeAll(where: { $0.alias == aliasKey })
    }

    func updateEndpointAuth(_ newValue: String) {
        endpointAuth = newValue
        _ = Keychain.setString(newValue, for: .endpointAuth)
    }
}
