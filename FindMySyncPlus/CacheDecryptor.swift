import Foundation
import CryptoKit

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

/// Where the Find My files are read from.
///
/// Normally the user's home directory. `demoRoot` points it at a fixture tree
/// instead, so screenshots can be taken against curated data without redacting
/// a real household. Inert unless the key is set, and it only ever changes where
/// files are *read* from — nothing is written through it.
enum ReadRoot {
    /// True when the app has been pointed at fixture data. The friend database
    /// is resolved by absolute path, so it has to be skipped explicitly in demo
    /// mode or it would reach the real one.
    static var isDemo: Bool {
        !(UserDefaults.standard.string(forKey: "demoRoot") ?? "").isEmpty
    }

    static var url: URL {
        if let path = UserDefaults.standard.string(forKey: "demoRoot"), !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}

enum FMIPCacheFile {
    case devices
    case items
    /// The second place Apple describes a group. A group is carried either as an
    /// embedded `itemGroup` on a device record or as a standalone record here, and the
    /// two share one identity — measured 2026-08-30, a parent's `baUUID` on one Mac and
    /// this file's `identifier` on another were byte-identical for the same AirPods.
    ///
    /// Same ChaChaPoly under `fmipSymmetricKey` as the other two, so it needs no new
    /// key and no new crypto. Absent on some machines, which the read path already
    /// treats as nothing rather than as an error.
    case itemGroups
    case friendCache

    var relativePath: String {
        switch self {
        case .devices:
            return "Library/Caches/com.apple.findmy.fmipcore/Devices.data"
        case .items:
            return "Library/Caches/com.apple.findmy.fmipcore/Items.data"
        case .itemGroups:
            return "Library/Caches/com.apple.findmy.fmipcore/ItemGroups.data"
        case .friendCache:
            return "Library/Caches/com.apple.findmy.fmfcore/FriendCacheData.data"
        }
    }
}

actor CacheDecryptor {
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

        let home = ReadRoot.url
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

    /// Why a record did or did not produce a position, for the Status window.
    ///
    /// Two negative cases, because two is all the data supports. There is deliberately
    /// no "sharing disabled" outcome: `locationCapable`, `locationEnabled` and
    /// `locFoundEnabled` were measured against a machine where Share My Location was
    /// switched off and back on, and none of them moved — the four devices that gained
    /// a position never changed a flag. Reporting one as a reason would send a user
    /// away from the actual cause.
    enum LocationOutcome: Equatable {
        /// A position was parsed. Carries what Apple said about it, verbatim.
        case located(positionType: String?, accuracyMetres: Double?, ageHours: Double?)
        /// Apple holds a Find My network sighting that was not published, because it
        /// is flagged old and publishing it would move the entity into a wrong zone.
        case cachedSightingDeclined(ageHours: Double?)
        /// Apple reports no position for this record at all.
        case nothingReported
    }

    /// Derived from `positionSource`, never from a second copy of the rule — otherwise
    /// the diagnostic can report a device as blank while Home Assistant shows it on
    /// the map, which is worse than saying nothing.
    nonisolated static func locationOutcome(for device: [String: Any],
                                            now: Date = Date()) -> LocationOutcome {
        func ageHours(_ raw: Any?) -> Double? {
            guard let millis = raw as? Double else { return nil }
            return (now.timeIntervalSince1970 - millis / 1000) / 3600
        }

        if let source = positionSource(for: device) {
            return .located(positionType: (source["positionType"] as? String).nonNullish,
                            accuracyMetres: source["horizontalAccuracy"] as? Double,
                            ageHours: ageHours(source["timeStamp"]))
        }
        if let sighting = device["crowdSourcedLocation"] as? [String: Any],
           sighting["latitude"] is Double {
            return .cachedSightingDeclined(ageHours: ageHours(sighting["timeStamp"]))
        }
        return .nothingReported
    }

    /// Which dictionary holds the position to publish, or nil when there is none.
    ///
    /// Find My shows a device as "Home · 9 hr. ago" from a Find My network sighting
    /// when it has nothing fresher. Reading only `location` meant publishing nothing
    /// at all for those records.
    ///
    /// `location` always wins when present — it is the fresher of the two. A
    /// `crowdSourcedLocation` rescues the record only when Apple flags it **not old**,
    /// and that guard is the whole safety of this. A sighting sitting behind a working
    /// primary location reads old (19 to 244 hours, sometimes hundreds of kilometres
    /// away), while a record with no primary at all reads fresh. Home Assistant
    /// computes zone state from the coordinates and ignores `is_old`, so publishing a
    /// stale sighting would move an entity into the wrong zone and fire automations.
    ///
    /// Absent is not false: Apple saying nothing about staleness is a different
    /// statement from Apple calling the fix current.
    nonisolated static func positionSource(for device: [String: Any]) -> [String: Any]? {
        let primary = device["location"] as? [String: Any]
        if primary?["latitude"] is Double { return primary }

        let sighting = device["crowdSourcedLocation"] as? [String: Any]
        return sighting?["isOld"] as? Bool == false ? sighting : nil
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
        let home = ReadRoot.url
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
    // `groupParentIDs` maps a child's `groupIdentifier` value to the parent's id (the
    // parent device's `baUUID`). Children whose `groupIdentifier` resolves get
    // `parentID` set; everything else gets `parentID == nil`. This function does
    // not rename items — naming/visibility decisions live upstream in SyncEngine.
    nonisolated func parseDeviceArray(
        _ decryptedArray: [[String: Any]],
        groupParentIDs: [String: String] = [:]
    ) -> [DevicePoint] {
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
                let loc = Self.positionSource(for: device),
                let lat = loc["latitude"] as? Double,
                let lon = loc["longitude"] as? Double,
                let acc = loc["horizontalAccuracy"] as? Double
            else {
                continue // skip no-location here (we'll log it in SyncEngine)
            }

            let batteryReading = Self.parseBattery(device)
            let prsId = (device["prsId"] as? String).nonNullish

            // Two levels down, under `productType` — there is no top-level
            // `productInformation`, and reading one finds nothing, which looks like
            // "no Apple items on this machine" rather than like a bug. The same dict
            // carries `manufacturerName` and `modelName`; `productType.type` is not a
            // model name, it holds internal codenames like "hawkeye".
            let productInfo = (device["productType"] as? [String: Any])?["productInformation"]
            let vendorIdentifier = (productInfo as? [String: Any])?["vendorIdentifier"] as? Int

            var parentID: String? = nil
            if !groupParentIDs.isEmpty,
               let gid = (device["groupIdentifier"] as? String).nonNullish {
                parentID = groupParentIDs[gid]
            }

            // FMIP carries freshness on every located device and item. It was read
            // only for the grouped-parent backfill in SyncEngine and then discarded,
            // so Items — which have no friend record to merge rich attributes from —
            // reached Home Assistant with no location timestamp at all (issue #17).
            let timestamp = (loc["timeStamp"] as? Double).map {
                Date(timeIntervalSince1970: $0 / 1000)
            }
            // `altitude` and `verticalAccuracy` are on every record measured and were
            // being dropped: friends published them while devices and items did not,
            // for no reason beyond this call site never being wired up.
            //
            // `speed` and `course` were not seen on any of 25 devices and 5 items —
            // but that was one instant, with nothing moving. A field that appears only
            // while a device is in motion would look identical to a field that does
            // not exist. So read them and let absent be absent, rather than encoding
            // an absence we cannot demonstrate.
            // A negative `verticalAccuracy` is CoreLocation's own way of saying the
            // altitude is invalid, and a crowdsourced fix carries -1 for both. Passing
            // them through hands a user a plausible-looking metre reading that means
            // "unavailable" — the sign is the test, never the altitude's own value,
            // since a real altitude can be negative.
            let verticalAccuracy = loc["verticalAccuracy"] as? Double
            let hasAltitude = (verticalAccuracy ?? -1) >= 0

            // Measured on a real Items.data 2026-08-30, which struck two candidates the
            // spec had proposed before anyone looked:
            //
            // `address.streetAddress` is the house number alone — `9`, `999` — so the
            // address line comes from `mediumAddressModern`, one of four widths Apple
            // pre-formats. No assembling, no parsing, and no fallback to another key:
            // a different width is a different answer, not a worse version of this one.
            //
            // `location.floorLevel` read `-1` on every item, which is CoreLocation's
            // "no value" and the same sentinel that reached Home Assistant as
            // `altitude: -1` earlier in this release. It is not read at all.
            // `role` is the category picked when an item is set up on iPhone — one of a
            // fixed list (Backpack, Keys, Wallet, …) with an emoji. Items only; a device
            // has none.
            //
            // Choosing to type a name instead stores the literal string "Custom Name"
            // here, *not* the name — that is carried by `name`, which is already
            // published. Measured on a live cache: four of five items read exactly that.
            // Publishing it would put "Custom Name" on most people's trackers, so the
            // placeholder is dropped and the attribute is simply absent, which is what it
            // means.
            let role = device["role"] as? [String: Any]
            let roleName = (role?["name"] as? String).nonNullish
            let address = (device["address"] as? [String: Any])?["mediumAddressModern"] as? String

            let rich = RichLocationAttributes(verticalAccuracy: hasAltitude ? verticalAccuracy : nil,
                                              altitude: hasAltitude ? loc["altitude"] as? Double : nil,
                                              speed: loc["speed"] as? Double,
                                              course: loc["course"] as? Double,
                                              timestamp: timestamp,
                                              motionActivityState: nil,
                                              locationLabel: nil,
                                              isOld: loc["isOld"] as? Bool,
                                              positionType: (loc["positionType"] as? String).nonNullish,
                                              isInaccurate: loc["isInaccurate"] as? Bool,
                                              role: roleName == "Custom Name" ? nil : roleName,
                                              roleEmoji: (role?["emoji"] as? String).nonNullish,
                                              address: address.nonNullish)

            results.append(DevicePoint(id: id,
                                       name: name,
                                       latitude: lat,
                                       longitude: lon,
                                       accuracy: acc,
                                       battery: batteryReading.level,
                                       batteryStatusCode: batteryReading.statusCode,
                                       chargingState: batteryReading.chargingState,
                                       vendorIdentifier: vendorIdentifier,
                                       prsId: prsId,
                                       richAttributes: rich,
                                       parentID: parentID))
        }

        return results
    }

    #if DEBUG
    func loadKeyForTesting(_ key: SymmetricKey) {
        fmipKey = key
    }
    #endif
}

extension CacheDecryptor {
    /// Battery as Apple actually stores it, kept separated by meaning rather than by
    /// key name. See `BatteryParsingTests` for why the two files can't share a field.
    struct BatteryReading: Equatable, Sendable {
        /// Genuine 0–1 charge level. Only ever from `batteryLevel`, never inferred.
        var level: Double?
        /// `Items.data` ordinal, passed through unmodified — its meaning varies by
        /// manufacturer and is not ours to guess.
        var statusCode: Int?
        /// `Devices.data` charging state string ("Charging" / "NotCharging" / "Unknown").
        var chargingState: String?
    }

    nonisolated static func namedBatteryLevel(_ raw: String) -> Double? {
        namedBatteryLevelImpl(raw)
    }

    nonisolated static func parseBattery(_ device: [String: Any]) -> BatteryReading {
        var reading = BatteryReading()

        // `batteryStatus` is a String on devices (a charging state) and an Int on items
        // (a battery ordinal). Split by type, because the key name doesn't tell you which.
        let status = device["batteryStatus"]

        if let code = status as? Int {
            // Items report an ordinal here. Passed through unmodified: its meaning
            // varies by manufacturer and is not ours to guess.
            reading.statusCode = code
        } else if let text = (status as? String).nonNullish {
            // Devices report a *charging state* here, but Apple has also been seen to
            // use named battery levels. The two vocabularies don't overlap, so the word
            // itself says which it is.
            if let named = Self.namedBatteryLevel(text) {
                reading.level = named
            } else {
                reading.chargingState = text
            }
        }

        if let level = device["batteryLevel"] as? Double {
            // An explicit level always wins over a named one.
            // A device with no battery still carries `batteryLevel = 0` — a desktop Mac
            // appears this way. Apple signals "nothing to report" by pairing that zero
            // with an Unknown charging state, so only then is it not a reading. A device
            // genuinely flat still reports Charging/NotCharging and keeps its 0.
            let noData = (level == 0 && reading.chargingState == "Unknown")
            if !noData {
                reading.level = max(0.0, min(1.0, level))
            }
        }

        return reading
    }
}

/// Apple's named battery levels. Returns nil for anything outside that vocabulary —
/// notably charging states, which use an entirely separate set of words.
private func namedBatteryLevelImpl(_ raw: String) -> Double? {
    switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "full", "max", "high":            return 1.0
    case "normal", "good":                 return 0.75
    case "medium", "fair":                 return 0.5
    case "low":                            return 0.25
    case "verylow", "critical", "very low": return 0.1
    default:
        // A numeric string is a level too — percentage or fraction.
        if let n = Double(raw) {
            return n > 1.0 ? max(0.0, min(1.0, n / 100.0)) : max(0.0, min(1.0, n))
        }
        return nil
    }
}
