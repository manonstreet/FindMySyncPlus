import Foundation
import SQLite3

// MARK: - Person location diagnostics
//
// Branch `diag/person-location` only — never in a release. Research for #34: which of a
// person's devices Apple's person record follows, measured on a setup we cannot build at
// home (a family member with an iPhone and a cellular Watch).
//
// One block per sync, logged at Debug and also kept in `PersonDiagnosticsLog`, so other log
// traffic cannot evict it before Copy Diagnostics. The block carries ages, accuracies,
// distances, device classes and Apple's raw codes — never coordinates, names or
// identifiers, because it is meant to be pasted on a public issue.
enum PersonLocationDiagnostics {

    /// One `secureLocations` row: a person's shared location, as Apple stored it.
    struct PersonRecord: Equatable {
        /// `serverUserID`, the person's DSID. Compared, never printed.
        let dsid: String
        let latitude: Double?
        let longitude: Double?
        let horizontalAccuracy: Double?
        let timestamp: Date?
        /// What `timestamp` was stored as — `Date` on macOS 27, which the app reads as a
        /// `Double`; a `Double` here would be news worth seeing.
        let timestampType: String
        /// Raw, whatever type Apple used; an unmapped code stays visible.
        let publishReason: String
        let motionActivityState: String
    }

    /// One row of the owner's `devices` table.
    struct OwnerDeviceRow: Equatable {
        /// `deviceIdentifier` and `idsDeviceId`. Compared, never printed.
        let identifiers: [String]
        /// `deviceName`, compared only as a fallback and never printed.
        let name: String?
        /// The flag columns present, in `flagColumns` order, raw.
        let flags: [String: String]
    }

    struct Snapshot: Equatable {
        var people: [PersonRecord] = []
        /// Nil when the table is absent, so "no table" and "no rows" read differently.
        var ownerDevices: [OwnerDeviceRow]?
        var autoMeCapableWatches: Int?
        /// Every coordinate in the database, for the search near each Watch.
        var stored: [StoredLocation] = []
        /// Why the snapshot is incomplete, if it is.
        var problems: [String] = []
    }

    static let flagColumns = ["deviceIsActive", "isThisDevice", "deviceIsCompanion",
                              "deviceIsAutoMeCapable", "isInQuickSwitchCircle"]

    // MARK: - Reading LocalStorage.db

    /// The person records and the owner's device bookkeeping, from the decrypted database the
    /// friends query reads. Read-only, and separate from `queryFriends`, so nothing published
    /// can differ because of it.
    nonisolated static func snapshot(database: Data) -> Snapshot {
        var snapshot = Snapshot()
        let db: OpaquePointer
        switch InMemorySQLite.open(database) {
        case .success(let handle): db = handle
        case .failure(let failure):
            snapshot.problems.append("could not open the database: \(failure.message)")
            return snapshot
        }
        defer { sqlite3_close(db) }

        if let rows = rows(db, "SELECT serverUserID, value FROM secureLocations") {
            snapshot.people = rows.compactMap(personRecord)
        } else {
            snapshot.problems.append("no secureLocations table")
        }
        snapshot.ownerDevices = rows(db, "SELECT * FROM devices")?.map { row in
            OwnerDeviceRow(
                identifiers: ["deviceIdentifier", "idsDeviceId"].compactMap { (row[$0] as? String).nonNullish },
                name: (row["deviceName"] as? String).nonNullish,
                flags: flagColumns.reduce(into: [:]) { flags, column in
                    if let value = row[column] { flags[column] = "\(value)" }
                })
        }
        if snapshot.ownerDevices == nil { snapshot.problems.append("no devices table") }
        snapshot.autoMeCapableWatches = rows(db, "SELECT COUNT(*) AS n FROM autoMeCapableWatches")?
            .first?["n"] as? Int
        snapshot.stored = storedLocations(db)
        return snapshot
    }

    nonisolated private static func personRecord(_ row: [String: Any]) -> PersonRecord? {
        guard let dsid = (row["serverUserID"] as? String).nonNullish,
              let blob = row["value"] as? Data,
              let value = try? PropertyListSerialization.propertyList(from: blob, options: [], format: nil)
                as? [String: Any] else { return nil }
        let raw = value["timestamp"]
        let timestamp: Date? = (raw as? Date) ?? (raw as? Double).map { Date(timeIntervalSinceReferenceDate: $0) }
        return PersonRecord(
            dsid: dsid,
            latitude: value["latitude"] as? Double,
            longitude: value["longitude"] as? Double,
            horizontalAccuracy: value["horizontalAccuracy"] as? Double,
            timestamp: timestamp,
            timestampType: raw.map(typeName) ?? "absent",
            publishReason: value["publishReason"].map { "\($0)" } ?? "absent",
            motionActivityState: value["motionActivityState"].map { "\($0)" } ?? "absent")
    }

    /// Every row as a dictionary, or nil when the statement does not prepare — a missing table.
    nonisolated static func rows(_ db: OpaquePointer, _ sql: String) -> [[String: Any]]? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        var out: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for column in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, column))
                switch sqlite3_column_type(stmt, column) {
                case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(stmt, column))
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, column)
                case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(stmt, column))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(stmt, column))
                    row[name] = count > 0 ? Data(bytes: sqlite3_column_blob(stmt, column), count: count) : Data()
                default: break
                }
            }
            out.append(row)
        }
        return out
    }

    nonisolated private static func typeName(_ value: Any) -> String {
        switch value {
        case is Date: return "Date"
        case let number as NSNumber: return CFNumberIsFloatType(number) ? "Double" : "Int"
        case is String: return "String"
        default: return "\(type(of: value))"
        }
    }

    // MARK: - The block

    /// The lines for one sync. `devices` and `items` are Devices.data and Items.data as
    /// decrypted, nil when that source is off; `snapshot` is nil when LocalStorage.db was not
    /// read this sync.
    nonisolated static func block(snapshot: Snapshot?, devices: [[String: Any]]?,
                                  items: [[String: Any]]? = nil, now: Date) -> [String] {
        guard let snapshot else {
            return ["no LocalStorage.db snapshot this sync — the Friends lines above say why"]
        }
        var lines = snapshot.problems.map { "problem: \($0)" }
        let devices = devices ?? []
        if devices.isEmpty { lines.append("no Devices.data records — is the Devices source on?") }

        let family = Dictionary(grouping: devices.filter {
            guard let prsId = ($0["prsId"] as? String).nonNullish else { return false }
            return prsId != "owner"
        }, by: { ($0["prsId"] as? String ?? "").normalized() })
        let records = Dictionary(snapshot.people.map { ($0.dsid.normalized(), $0) },
                                 uniquingKeysWith: { first, _ in first })

        // Family first, then people who share only their location; each in DSID order, which
        // stays put from sync to sync while the people do. A person outside the family still
        // gets their record line: its age and accuracy over a walk are the finding even with
        // no devices to compare it with.
        let outsideFamily = Set(records.keys).subtracting(family.keys).sorted()
        let order = family.keys.sorted() + outsideFamily
        let person = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0 + 1) })
        for (index, dsid) in order.enumerated() {
            lines += personLines(number: index + 1, record: records[dsid], devices: family[dsid] ?? [], now: now) { watch, label in
                nearestLine(to: watch, label: label, stored: snapshot.stored, devices: devices,
                            items: items ?? [], person: person, now: now)
            }
        }
        lines += ownerLines(snapshot, devices: devices)
        // Where the database holds coordinates at all — a Watch's location stored somewhere
        // unexpected would show here even on a sync where no Watch has a fix.
        let bySource = Dictionary(grouping: snapshot.stored, by: \.source)
            .map { "\($0.key) ×\($0.value.count)" }.sorted()
        lines.append("coordinates in LocalStorage.db: " + (bySource.isEmpty ? "none" : bySource.joined(separator: ", ")))
        return lines
    }

    /// `near` gives the line of stored locations nearest a located Watch.
    nonisolated private static func personLines(number: Int, record: PersonRecord?,
                                                devices: [[String: Any]], now: Date,
                                                near: ([String: Any], String) -> String?) -> [String] {
        var lines: [String] = []
        if let record {
            var parts = ["record \(age(record.timestamp, now: now))"]
            parts.append(record.horizontalAccuracy.map { "±\(Int($0.rounded())) m" } ?? "no accuracy")
            parts.append("publishReason \(record.publishReason)")
            parts.append("motionActivityState \(record.motionActivityState)")
            parts.append("timestamp stored as \(record.timestampType)")
            lines.append("person \(number): \(parts.joined(separator: ", "))")
        } else {
            lines.append("person \(number): no person record — not sharing a location with this account")
        }
        if devices.isEmpty {
            lines.append("    no devices on this Mac — shares a location, outside this account's family")
            return lines
        }

        let recordPosition = record.flatMap { r in r.latitude.flatMap { lat in r.longitude.map { (lat, $0) } } }
        // By class, then by id, so the same device keeps its line and its number.
        let sorted = devices.sorted {
            (deviceClass($0), CacheDecryptor.resolveID($0) ?? "") < (deviceClass($1), CacheDecryptor.resolveID($1) ?? "")
        }
        var seen: [String: Int] = [:]
        // One line for the devices with nothing to compare, which on a family's iPads, Macs
        // and accessories is often most of them.
        var unlocated: [String] = []
        for device in sorted {
            let cls = deviceClass(device)
            let count = seen[cls, default: 0] + 1
            seen[cls] = count
            let label = count > 1 ? "\(cls) \(count)" : cls
            if let description = deviceDescription(device, recordPosition: recordPosition, now: now) {
                lines.append("    \(label): \(description)")
                if cls.localizedCaseInsensitiveContains("watch"), let line = near(device, label) {
                    lines.append(line)
                }
            } else {
                unlocated.append(label)
            }
        }
        if !unlocated.isEmpty {
            lines.append("    plus \(unlocated.count) with no location: \(unlocated.joined(separator: ", "))")
        }
        return lines
    }

    /// Nil when the device has no position to compare.
    nonisolated private static func deviceDescription(_ device: [String: Any],
                                                      recordPosition: (Double, Double)?, now: Date) -> String? {
        guard case let .located(type, accuracy, ageHours) = CacheDecryptor.locationOutcome(for: device, now: now),
              let fix = CacheDecryptor.positionSource(for: device),
              let lat = fix["latitude"] as? Double, let lon = fix["longitude"] as? Double else {
            return nil
        }
        var parts: [String] = []
        if let recordPosition {
            parts.append("\(distanceDescription(meters(recordPosition, (lat, lon)))) from the record")
        }
        parts.append("fix " + (ageHours.map { age(seconds: $0 * 3600) } ?? "of unknown age"))
        parts.append(accuracy.map { "±\(Int($0.rounded())) m" } ?? "no accuracy")
        parts.append(type ?? "no positionType")
        return parts.joined(separator: ", ")
    }

    nonisolated private static func ownerLines(_ snapshot: Snapshot, devices: [[String: Any]]) -> [String] {
        guard let rows = snapshot.ownerDevices else { return [] }
        let active = rows.filter { $0.flags["deviceIsActive"] == "1" }
        var lines = ["owner: \(rows.count) devices row(s), \(active.count) active; "
                     + "autoMeCapableWatches \(snapshot.autoMeCapableWatches.map(String.init) ?? "absent")"]
        let owned = devices.filter { ($0["prsId"] as? String) == "owner" }
        for row in active {
            let flags = flagColumns.map { "\($0)=\(row.flags[$0] ?? "absent")" }.joined(separator: " ")
            lines.append("    active: \(match(row, in: owned)) — \(flags)")
        }
        return lines
    }

    /// Identifiers against every string field of the owner's records — `deviceDiscoveryId`
    /// first, the field the link was measured on, then the rest in name order so the line is
    /// the same every sync — then the name. Says how it matched, never what it matched on.
    nonisolated private static func match(_ row: OwnerDeviceRow, in owned: [[String: Any]]) -> String {
        let wanted = Set(row.identifiers.map { $0.normalized() }.filter { !$0.isEmpty })
        for record in owned {
            let keys = ["deviceDiscoveryId"] + record.keys.sorted().filter { $0 != "deviceDiscoveryId" }
            let hit = keys.first { key in
                (record[key] as? String).map { wanted.contains($0.normalized()) } ?? false
            }
            if let hit { return "\(deviceClass(record)) (matched on `\(hit)`)" }
        }
        if let name = row.name {
            let hits = owned.filter { ($0["name"] as? String) == name }
            if hits.count == 1 { return "\(deviceClass(hits[0])) (matched on name only)" }
            if hits.count > 1 { return "ambiguous — \(hits.count) of the owner's devices share its name" }
        }
        return "no match among the owner's devices — class unknown"
    }

    // MARK: - Formatting

    nonisolated static func deviceClass(_ device: [String: Any]) -> String {
        (device["deviceClass"] as? String).nonNullish
            ?? (device["modelDisplayName"] as? String).nonNullish
            ?? (device["deviceModel"] as? String).nonNullish
            ?? "unknown class"
    }

    nonisolated private static func age(_ date: Date?, now: Date) -> String {
        date.map { age(seconds: now.timeIntervalSince($0)) } ?? "of unknown age"
    }

    /// `75 s old`, `12 min old`, `3.2 h old`; a future time keeps its sign — clock skew.
    nonisolated static func age(seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if abs(s) < 120 { return "\(s) s old" }
        if abs(s) < 7200 { return "\(s / 60) min old" }
        return String(format: "%.1f h old", seconds / 3600)
    }

    nonisolated static func distanceDescription(_ meters: Double) -> String {
        meters < 1000 ? "\(Int(meters.rounded())) m" : String(format: "%.1f km", meters / 1000)
    }

    /// Great-circle metres between two coordinates.
    nonisolated static func meters(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
        let r = 6_371_000.0, p1 = a.0 * .pi / 180, p2 = b.0 * .pi / 180
        let dp = (b.0 - a.0) * .pi / 180, dl = (b.1 - a.1) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }
}

// MARK: - The kept blocks

/// The recent blocks, apart from the log so its 5000-entry cap cannot drop them.
@MainActor
final class PersonDiagnosticsLog {
    static let shared = PersonDiagnosticsLog()

    /// Three hours at a one-minute interval: a walk and the time either side of it, in a
    /// file small enough to attach to a comment however long the app has been running.
    static let cap = 180

    private(set) var blocks: [(at: Date, lines: [String])] = []
    /// How many older blocks the cap has dropped, which the file header reports.
    private(set) var dropped = 0

    func append(_ lines: [String], at date: Date) {
        blocks.append((date, lines))
        if blocks.count > Self.cap {
            dropped += blocks.count - Self.cap
            blocks.removeFirst(blocks.count - Self.cap)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// What Save Diagnostics writes: a header naming the build and the system, then the blocks.
    func plainText(syncIntervalSeconds: Double) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let commit = (info["GitCommit"] as? String).nonNullish ?? "unstamped"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var out = ["FindMySync+ person location diagnostics — \(version) (\(commit)), "
                   + "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion), "
                   + "sync every \(Int(syncIntervalSeconds / 60)) min, \(blocks.count) sync(s)"
                   + (dropped > 0 ? ", \(dropped) older dropped" : "")]
        for block in blocks {
            out.append("")
            out.append("== sync \(Self.timeFormatter.string(from: block.at))")
            out += block.lines
        }
        return out.joined(separator: "\n")
    }
}
