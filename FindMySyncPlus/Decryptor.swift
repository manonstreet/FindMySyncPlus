import Foundation
import CryptoKit

private struct HAPayload: Codable {
    let dev_id: String
    let host_name: String
    let mac: String
    let gps: [Double]
    let gps_accuracy: Double
    let battery: Int?
}

private actor AsyncSemaphore {
    private var value: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) {
        self.value = max(1, value)
    }

    func wait() async {
        if value > 0 {
            value -= 1
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    func signal() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        } else {
            value += 1
        }
    }
}

struct DevicePoint: Sendable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
    let accuracy: Double
    let battery: Double?
    let prsId: String?     // person ID (base64 DSID); "owner" for self, DSID for family devices

    init(id: String, name: String, latitude: Double, longitude: Double, accuracy: Double, battery: Double?, prsId: String? = nil) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
        self.battery = battery
        self.prsId = prsId
    }
}

enum DecryptorError: LocalizedError {
    case fdaRequired
    case keyNotLoaded
    case fileReadError(Error)
    case incorrectKey
    case invalidPayloadFormat(String)
    case decryptionFailed(Error)

    var errorDescription: String? {
        switch self {
        case .fdaRequired:
            return "Full Disk Access is required to read the Find My cache."
        case .keyNotLoaded:
            return "FMIP decryption key is not loaded in memory."
        case .fileReadError(let underlyingError):
            return "Cannot read Find My cache file: \(underlyingError.localizedDescription)"
        case .incorrectKey:
            return "Decrypt failed: The provided decryption key is incorrect for this data. Please re-import the correct key."
        case .invalidPayloadFormat(let reason):
            return "The Find My cache file has an invalid format: \(reason)"
        case .decryptionFailed(let underlyingError):
            return "Decrypt failed: \(underlyingError.localizedDescription)"
        }
    }
}

enum AuthError: LocalizedError {
    case invalidURL(String)
    case requestFailed(Int)
    case authRejected(Int)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let reason):
            return "Auth Test Failed: \(reason)"
        case .requestFailed(let status):
            return "Auth Test Failed: Server responded with HTTP status \(status)."
        case .authRejected(let status):
            return "Auth Test Failed: Authentication was rejected (HTTP \(status)). Check your Authorization Header."
        case .networkError(let error):
            return "Auth Test Failed: \(error.localizedDescription)"
        }
    }
}

private enum PostResult: Sendable {
    case success(id: String, status: Int)
    case authRejected(id: String, status: Int)   // 401/403
    case transient(id: String, reason: String)   // network/other HTTP
}

struct PostSummary: Sendable {
    let successCount: Int
    let authRejectedCount: Int
    let transientCount: Int
}

enum FMIPCacheFile {
    case devices
    case items
    case friendCache

    var relativePath: String {
        switch self {
        case .devices:
            return "Library/Caches/com.apple.findmy.fmipcore/Devices.data"
        case .items:
            return "Library/Caches/com.apple.findmy.fmipcore/Items.data"
        case .friendCache:
            return "Library/Caches/com.apple.findmy.fmfcore/FriendCacheData.data"
        }
    }
}

actor Decryptor {
    private var fmipKey: SymmetricKey?
    private var fmfKey: SymmetricKey?

    func invalidateKey() { fmipKey = nil }
    func invalidateFMFKey() { fmfKey = nil }

    func ensureFMIPKey(logger: LogStore) {
        guard fmipKey == nil else { return }
        if let raw = Keychain.getData(for: .fmipSymmetricKey) {
            let count = raw.count
            guard count == 32 else {
                logger.error("FMIP key has unexpected length: \(count) bytes; expected 32. Please re-import the key.")
                return
            }
            fmipKey = SymmetricKey(data: raw)
            logger.info("FMIP key loaded from Keychain (\(count) bytes)")
            logger.debug("Keychain location: \(Bundle.main.bundleIdentifier ?? "com.manonstreet.findmysyncplus")")
        } else {
            logger.error("FMIP key not found in Keychain. Use Extras -> Load Key to import.")
        }
    }
    
    func ensureFMFKey(logger: LogStore) {
        guard fmfKey == nil else { return }
        if let raw = Keychain.getData(for: .fmfKey) {
            let count = raw.count
            guard count == 32 else {
                logger.error("FMF key has unexpected length: \(count) bytes; expected 32. Please re-import the key.")
                return
            }
            fmfKey = SymmetricKey(data: raw)
            logger.info("FMF key loaded from Keychain (\(count) bytes)")
        } else {
            logger.debug("FMF key not found in Keychain; friend name lookup unavailable.")
        }
    }

    /// Decrypt FriendCacheData.data and extract contact display names.
    /// Returns a mapping of DSID → displayName, or nil if decryption failed/unavailable.
    func readFMFContactNames(logger: LogStore) -> [String: String]? {
        guard let key = fmfKey else { return nil }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let fileURL = home.appendingPathComponent(FMIPCacheFile.friendCache.relativePath)

        let outerData: Data
        do {
            outerData = try Data(contentsOf: fileURL)
        } catch {
            logger.debug("FMF cache not found or unreadable: \(error.localizedDescription)")
            return nil
        }

        // Parse outer plist to get encryptedData
        guard let outerPL = try? PropertyListSerialization.propertyList(from: outerData, options: [], format: nil),
              let outer = outerPL as? [String: Any],
              let encrypted = outer["encryptedData"] as? Data,
              encrypted.count >= (12 + 16) else {
            logger.debug("FMF cache: no encryptedData found or too short")
            return nil
        }

        // Decrypt with ChaChaPoly (same scheme as FMIP)
        let plaintext: Data
        do {
            plaintext = try Self.chaChaPolyOpen(encrypted, using: key)
        } catch {
            logger.debug("FMF cache decrypt failed: \(error.localizedDescription)")
            return nil
        }

        // Parse decrypted plist — expected structure: dict with "contacts" key
        guard let innerPL = try? PropertyListSerialization.propertyList(from: plaintext, options: [], format: nil),
              let root = innerPL as? [String: Any],
              let contacts = root["contacts"] as? [String: Any] else {
            logger.debug("FMF cache: decrypted data has no contacts dict")
            return [:]
        }

        var names: [String: String] = [:]
        for (dsid, value) in contacts {
            guard let info = value as? [String: Any] else { continue }
            if let displayName = info["displayName"] as? String, !displayName.isEmpty {
                names[dsid] = displayName
            } else if let shortName = info["shortName"] as? String, !shortName.isEmpty {
                names[dsid] = shortName
            }
        }

        if !names.isEmpty {
            logger.debug("FMF contacts: loaded \(names.count) display name(s)")
        }
        return names
    }

    /// Shared ChaChaPoly decryption: nonce (12 bytes) || ciphertext || tag (16 bytes).
    nonisolated static func chaChaPolyOpen(_ encrypted: Data, using key: SymmetricKey) throws -> Data {
        let nonce = encrypted.prefix(12)
        let ciphertextWithTag = encrypted.suffix(from: 12)
        let ciphertext = ciphertextWithTag.prefix(ciphertextWithTag.count - 16)
        let tag = ciphertextWithTag.suffix(16)
        let sealed = try ChaChaPoly.SealedBox(nonce: .init(data: nonce), ciphertext: ciphertext, tag: tag)
        return try ChaChaPoly.open(sealed, using: key)
    }

    nonisolated static func extractSymmetricKey(from any: Any) throws -> Data? {
        if let s = any as? String, let raw = Data(base64Encoded: s) { return raw }
        if let d = any as? Data {
            if d.count == 32 { return d }
            if let asString = String(data: d, encoding: .utf8), let raw = Data(base64Encoded: asString) {
                return raw
            }
            return nil
        }
        if let dict = any as? [String: Any] {
            if let sk = dict["symmetricKey"], let raw = try extractSymmetricKey(from: sk) { return raw }
            if let k = dict["key"], let raw = try extractSymmetricKey(from: k) { return raw }
            if let dataField = dict["data"], let raw = try extractSymmetricKey(from: dataField) { return raw }
        }
        return nil
    }
    
    func readEncryptedPayload(from file: FMIPCacheFile, logger: LogStore) -> Result<Data, DecryptorError> {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fileURL = home.appendingPathComponent(file.relativePath)
        
        let outerData: Data
        do {
            outerData = try Data(contentsOf: fileURL)
            Task { @MainActor in logger.needsFullDiskAccess = false }
        } catch {
            if error.isPermissionDenied {
                Task { @MainActor in logger.needsFullDiskAccess = true }
                return .failure(.fdaRequired)
            } else {
                return .failure(.fileReadError(error))
            }
        }
        
        do {
            let outerPL = try PropertyListSerialization.propertyList(from: outerData, options: [], format: nil)
            guard let outer = outerPL as? [String: Any],
                  let encrypted = outer["encryptedData"] as? Data,
                  encrypted.count >= (12 + 16) else {
                return .failure(.invalidPayloadFormat("Could not find 'encryptedData' key or data was too short."))
            }
            return .success(encrypted)
        } catch {
            return .failure(.invalidPayloadFormat("Outer plist could not be deserialized."))
        }
    }
    
    func decryptPayload(_ encryptedPayload: Data, logger: LogStore) -> Result<Data, DecryptorError> {
        guard let key = fmipKey else {
            return .failure(.keyNotLoaded)
        }

        do {
            let plaintext = try Self.chaChaPolyOpen(encryptedPayload, using: key)
            return .success(plaintext)
        } catch let error as CryptoKit.CryptoKitError where error == .authenticationFailure {
            return .failure(.incorrectKey)
        } catch {
            return .failure(.decryptionFailed(error))
        }
    }

    // Parses decrypted plist Data into an array of device dictionaries.
    nonisolated func parsePlistData(_ plaintext: Data) -> Result<[[String: Any]], DecryptorError> {
        do {
            let innerPL = try PropertyListSerialization.propertyList(from: plaintext, options: [], format: nil)
            guard let arr = innerPL as? [[String: Any]] else {
                return .failure(.invalidPayloadFormat("Decrypted data was not an array of devices."))
            }
            return .success(arr)
        } catch {
            return .failure(.invalidPayloadFormat("Decrypted plist could not be deserialized."))
        }
    }
        
    // Returns only devices that have a valid location.
    nonisolated func parseDeviceArray(_ decryptedArray: [[String: Any]]) -> [DevicePoint] {
        var results: [DevicePoint] = []
        results.reserveCapacity(decryptedArray.count)

        for device in decryptedArray {
            let id =
                (device["baUUID"] as? String).nonNullish ??
                (device["deviceDiscoveryId"] as? String).nonNullish ??
                (device["identifier"] as? String).nonNullish ??
                (device["serialNumber"] as? String).nonNullish
            guard let id else { continue }

            let name = (device["name"] as? String) ?? ""

            guard
                let loc = device["location"] as? [String: Any],
                let lat = loc["latitude"] as? Double,
                let lon = loc["longitude"] as? Double,
                let acc = loc["horizontalAccuracy"] as? Double
            else {
                continue // skip no-location here (we'll log it in AppModel)
            }

            let battery = (device["batteryLevel"] as? Double) ?? batteryFromStatus(device["batteryStatus"])
            let prsId = (device["prsId"] as? String).nonNullish

            results.append(DevicePoint(id: id,
                                       name: name,
                                       latitude: lat,
                                       longitude: lon,
                                       accuracy: acc,
                                       battery: battery,
                                       prsId: prsId))
        }

        return results
    }
    
    #if DEBUG
    func loadKeyForTesting(_ key: SymmetricKey) {
        fmipKey = key
    }
    #endif

    @MainActor func testEndpointAuthentication(settings: SettingsStore) async throws {
        guard
            let fullURL = URL(string: settings.endpointURL),
            let scheme = fullURL.scheme, scheme.hasPrefix("http"),
            let host = fullURL.host
        else {
            throw AuthError.invalidURL("Invalid URL format")
        }
        
        guard fullURL.path.range(of: #"^/api(?:/|$)"#, options: .regularExpression) != nil else {
            throw AuthError.invalidURL("URL path must start with /api")
        }
        
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = fullURL.port
        components.path = "/api/"
        
        guard let testURL = components.url else {
            throw AuthError.invalidURL("Could not construct base /api/ URL")
        }
        
        var req = URLRequest(url: testURL)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let trimmed = settings.endpointAuth.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            req.setValue(trimmed, forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 12
        
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw AuthError.requestFailed(-1)
            }
            
            let status = http.statusCode
            if (200...299).contains(status) {
                return // Success!
            } else if status == 401 || status == 403 {
                throw AuthError.authRejected(status)
            } else {
                throw AuthError.requestFailed(status)
            }
        } catch {
            if let authError = error as? AuthError {
                throw authError // Re-throw our specific error
            }
            throw AuthError.networkError(error) // Wrap any other error
        }
    }
    
    @MainActor func post(_ devices: [DevicePoint],
              aliasByUUID: [String: String],
              settings: SettingsStore,
              logger: LogStore,
              dryRun: Bool = false) async -> PostSummary {
        
        if dryRun {
            for d in devices {
                let uuid = d.id.normalized()
                if let alias = aliasByUUID[uuid] {
                    let dev = "findmy_\(alias)"
                    let mac = macFromAlias(alias)
                    logger.info("[DRY] Would post dev_id=\(dev), host_name=\(dev), mac=\(mac)")
                } else {
                    // Defensive (toPost should already be filtered)
                    logger.warn("[DRY] Skipping \(uuid): no alias mapping found")
                }
            }
            return PostSummary(successCount: 0, authRejectedCount: 0, transientCount: 0)
        }
        
        let endpointURL = settings.endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: endpointURL), !endpointURL.isEmpty else {
            logger.error("Invalid endpoint URL")
            return PostSummary(successCount: 0, authRejectedCount: 0, transientCount: 0)
        }
        let authHeader = settings.endpointAuth.trimmingCharacters(in: .whitespacesAndNewlines)
        
        var successCount = 0
        var authRejectedCount = 0
        var transientCount = 0
        
        let semaphore = AsyncSemaphore(value: 8)
        
        await withTaskGroup(of: PostResult.self) { group in
            for d in devices {
                group.addTask { @Sendable in
                    await semaphore.wait()
                    defer { Task { await semaphore.signal() } }
                    let result: PostResult

                    // Resolve alias (toPost should ensure this exists)
                    let uuid = d.id.normalized()
                    guard let alias = aliasByUUID[uuid] else {
                        result = .transient(id: d.id, reason: "No alias for UUID \(uuid)")
                        return result
                    }

                    let dev = "findmy_\(alias)"  // dev_id and host_name must match for HA
                    let mac = macFromAlias(alias)

                    // Build payload per HA behavior using Codable
                    let payload = HAPayload(
                        dev_id: dev,
                        host_name: dev,
                        mac: mac,
                        gps: [d.latitude, d.longitude],
                        gps_accuracy: d.accuracy,
                        battery: d.battery.map { Int(($0 * 100).rounded()) }
                    )
                    
                    // Encode once per task (JSONEncoder isn't guaranteed thread-safe)
                    guard let body = try? JSONEncoder().encode(payload) else {
                        result = .transient(id: d.id, reason: "Failed to encode JSON payload.")
                        return result
                    }
                    
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.httpBody = body
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if !authHeader.isEmpty {
                        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
                    }

                    do {
                        let (_, response) = try await URLSession.shared.data(for: req)
                        if let http = response as? HTTPURLResponse {
                            let status = http.statusCode
                            if status == 401 || status == 403 {
                                result = .authRejected(id: d.id, status: status)
                            } else if (200...299).contains(status) {
                                result = .success(id: dev, status: status)
                            } else {
                                result = .transient(id: dev, reason: "HTTP \(status)")
                            }
                        } else {
                            result = .transient(id: dev, reason: "Non-HTTP response")
                        }
                    } catch {
                        result = .transient(id: dev, reason: "POST request failed with network error: \(error.localizedDescription)")
                    }

                    return result
                }
            }
            
            for await result in group {
                switch result {
                case .success(let id, let status):
                    successCount += 1
                    logger.info("[\(id)] Data sent: HTTP \(status)")
                case .authRejected(let id, let status):
                    authRejectedCount += 1
                    logger.error("[\(id)] Authentication failed (HTTP \(status)). Check your Authorization header.")
                case .transient(let id, let reason):
                    transientCount += 1
                    logger.warn("[\(id)] POST failed: \(reason)")
                }
            }
        }
        
        return PostSummary(successCount: successCount,
                           authRejectedCount: authRejectedCount,
                           transientCount: transientCount)
    }
}


private func batteryFromStatus(_ any: Any?) -> Double? {
    // Accept a few common shapes for Items:
    // - String statuses like "full", "normal", "medium", "low", "verylow", "critical"
    // - Numeric percentages (0-100)
    // - Fractions (0.0-1.0)
    if let d = any as? Double {
        if d.isNaN || d.isInfinite { return nil }
        return d > 1.0 ? max(0.0, min(1.0, d / 100.0)) : max(0.0, min(1.0, d))
    }
    if let i = any as? Int {
        return max(0.0, min(1.0, Double(i) / 100.0))
    }
    if let s = (any as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        switch s {
        case "full", "max", "high":
            return 1.0
        case "normal", "good":
            return 0.75
        case "medium", "fair":
            return 0.5
        case "low":
            return 0.25
        case "verylow", "critical", "very low":
            return 0.1
        default:
            // Try to parse numeric-in-string (either percent or fraction)
            if let asNum = Double(s) {
                return asNum > 1.0 ? max(0.0, min(1.0, asNum / 100.0)) : max(0.0, min(1.0, asNum))
            }
            return nil
        }
    }
    return nil
}

