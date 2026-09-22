import Foundation

// MARK: - Location diagnostics
//
// "Why is this device blank in Home Assistant" is answerable in the app, live, with no
// export and no support round trip.
extension SyncEngine {

    /// Says why each record did or did not produce a position, and returns how many
    /// produced none. The reason comes from `CacheDecryptor.locationOutcome`, built on the
    /// same `positionSource` the parser uses — a second copy of that rule could report a
    /// device as blank while Home Assistant shows it on the map.
    /// - Parameter locatedIDs: normalized ids that produced a point after the whole read
    ///   phase, revival included, so a group parent given its child's position is not
    ///   reported blank while the app publishes it.
    func logLocationOutcomes(rawBySource: [FMIPCacheFile: [[String: Any]]],
                             locatedIDs: Set<String>,
                             logger: LogStore) -> Int {
        var noLocationCount = 0

        for (source, raws) in [("Devices", rawBySource[.devices] ?? []),
                               ("Items", rawBySource[.items] ?? [])] {
            var cachedOnly = 0
            var nothingReported = 0

            for raw in raws {
                let id = normalizeID(raw["baUUID"]) ?? normalizeID(raw["deviceDiscoveryId"])
                    ?? normalizeID(raw["identifier"])
                guard let id else { continue }
                let name = (raw["name"] as? String) ?? ""

                // Each line states what is true of the record. Revived parents are located,
                // whatever their own record says.
                if locatedIDs.contains(id), case .nothingReported = CacheDecryptor.locationOutcome(for: raw) {
                    logger.debug("- \(name) (\(id)): located from its grouped items")
                    continue
                }

                switch CacheDecryptor.locationOutcome(for: raw) {
                case let .located(type, accuracy, age):
                    logger.debug("- \(name) (\(id)): located, \(Self.fixDescription(type, accuracy, age))")
                case let .cachedSightingDeclined(age):
                    let when = age.map { "\(Self.ageDescription($0)) old" } ?? "age unknown"
                    logger.debug("- \(name) (\(id)): only a cached sighting, \(when), not published")
                    cachedOnly += 1
                case .nothingReported:
                    logger.debug("- \(name) (\(id)): no position recorded")
                    nothingReported += 1
                }
            }

            noLocationCount += cachedOnly + nothingReported

            // One .info line per source per run: a per-device line at this level would turn
            // the 5000-entry buffer over in hours at the default interval. Per-device detail
            // is .debug, which is not even built unless someone raises the level.
            if let summary = Self.noLocationSummary(source: source, total: raws.count,
                                                    cachedOnly: cachedOnly,
                                                    nothingReported: nothingReported) {
                logger.info(summary)
            }
        }
        return noLocationCount
    }

    /// `0h3m`, `19h24m`. Fractions of an hour read badly: a three-minute-old fix as `0.0h`
    /// looks like missing data. A future timestamp means clock skew and keeps its sign,
    /// since clamping to zero would disguise it as a fresh fix.
    nonisolated static func ageDescription(_ hours: Double) -> String {
        let totalMinutes = Int((hours * 60).rounded())
        let sign = totalMinutes < 0 ? "-" : ""
        let magnitude = abs(totalMinutes)
        return "\(sign)\(magnitude / 60)h\(magnitude % 60)m"
    }

    /// `type=Wifi acc=13.7m age=0h3m`, omitting whatever Apple did not supply.
    /// `positionType` passes through verbatim — `GPS`, `Wifi`, `crowdsourced` and
    /// `ownedDeviceLocation` are the observed values, and an unmapped one must stay
    /// visible rather than be folded into a default.
    nonisolated static func fixDescription(_ type: String?,
                                           _ accuracyMeters: Double?,
                                           _ ageHours: Double?) -> String {
        var parts: [String] = []
        if let type { parts.append("type=\(type)") }
        if let accuracyMeters { parts.append(String(format: "acc=%.1fm", accuracyMeters)) }
        if let ageHours { parts.append("age=\(Self.ageDescription(ageHours))") }
        return parts.isEmpty ? "no detail reported" : parts.joined(separator: " ")
    }

    /// The one line a user sees by default when a source produced records with no position,
    /// or nil when everything was located. The closing sentence is guidance, not a finding:
    /// no readable field tracks those settings. It stays generic because Share My Location
    /// governs sharing with people, while a device's own position depends on Location
    /// Services and the Find My toggle.
    nonisolated static func noLocationSummary(source: String,
                                              total: Int,
                                              cachedOnly: Int,
                                              nothingReported: Int) -> String? {
        let missing = cachedOnly + nothingReported
        guard missing > 0 else { return nil }

        // No special line for an all-blank source: a stale cache holds old coordinates, not
        // missing ones, and any account-wide cause is a guess.
        var reasons: [String] = []
        if cachedOnly > 0 { reasons.append("\(cachedOnly) with only a cached sighting") }
        if nothingReported > 0 { reasons.append("\(nothingReported) with nothing reported") }

        var line = "\(source): \(missing) of \(total) have no location — \(reasons.joined(separator: ", "))."
        if nothingReported > 0 {
            line += " Common causes are the tracked device being offline,"
                + " or its location and sharing settings."
        }
        return line
    }
}
