import Foundation
import SQLite3

// MARK: - What is stored near each Watch
//
// Branch `diag/person-location` only. If Find My did hand a person's shared location to
// their Watch, the Mac might hold it somewhere other than `secureLocations`. This finds
// every coordinate the Mac holds — every table in LocalStorage.db with its plists decoded,
// and the device and item caches — and lists the ones nearest each Watch, named by where
// they are stored. Coordinates are compared and never printed.
extension PersonLocationDiagnostics {

    /// A coordinate found in LocalStorage.db.
    struct StoredLocation: Equatable {
        /// `table.column`, then the key path inside a decoded plist.
        let source: String
        /// The row's `serverUserID`, when it has one, so a person's record can be named.
        let dsid: String?
        let latitude: Double
        let longitude: Double
        let time: Date?
    }

    /// The key pairs a coordinate has been seen under in Apple's records.
    private static let coordinateKeys = [("latitude", "longitude"), ("lat", "lon"), ("lat", "lng")]

    nonisolated static func storedLocations(_ db: OpaquePointer) -> [StoredLocation] {
        let tables = rows(db, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")?
            .compactMap { $0["name"] as? String } ?? []
        var found: [StoredLocation] = []
        for table in tables {
            for row in rows(db, "SELECT * FROM \"\(table)\"") ?? [] {
                let dsid = (row["serverUserID"] as? String).nonNullish
                if let (lat, lon) = coordinate(in: row) {
                    found.append(StoredLocation(source: table, dsid: dsid, latitude: lat, longitude: lon, time: nil))
                }
                for (column, value) in row.sorted(by: { $0.key < $1.key }) {
                    guard let blob = value as? Data, !blob.isEmpty,
                          let plist = try? PropertyListSerialization.propertyList(from: blob, options: [], format: nil)
                    else { continue }
                    collect(plist, path: "\(table).\(column)", dsid: dsid, into: &found)
                }
            }
        }
        return found
    }

    nonisolated private static func collect(_ value: Any, path: String, dsid: String?,
                                            into found: inout [StoredLocation]) {
        if let dict = value as? [String: Any] {
            if let (lat, lon) = coordinate(in: dict) {
                found.append(StoredLocation(source: path, dsid: dsid, latitude: lat, longitude: lon, time: time(in: dict)))
            }
            for (key, child) in dict.sorted(by: { $0.key < $1.key }) {
                collect(child, path: "\(path).\(safeKey(key))", dsid: dsid, into: &found)
            }
        } else if let array = value as? [Any] {
            for child in array { collect(child, path: "\(path)[]", dsid: dsid, into: &found) }
        } else if let data = value as? Data,
                  let nested = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
            collect(nested, path: path, dsid: dsid, into: &found)
        }
    }

    /// A plist key as printed: a field name stays, anything else — a dictionary keyed by an
    /// identifier — becomes `*`.
    nonisolated static func safeKey(_ key: String) -> String {
        key.range(of: "^[$A-Za-z][A-Za-z_]{0,39}$", options: .regularExpression) != nil ? key : "*"
    }

    nonisolated private static func coordinate(in dict: [String: Any]) -> (Double, Double)? {
        for (latKey, lonKey) in coordinateKeys {
            guard let lat = (dict[latKey] as? NSNumber)?.doubleValue,
                  let lon = (dict[lonKey] as? NSNumber)?.doubleValue,
                  abs(lat) <= 90, abs(lon) <= 180, lat != 0 || lon != 0 else { continue }
            return (lat, lon)
        }
        return nil
    }

    /// A Date, or a number read by its size: milliseconds or seconds since 1970, else seconds
    /// since 2001.
    nonisolated private static func time(in dict: [String: Any]) -> Date? {
        for key in ["timestamp", "timeStamp"] {
            if let date = dict[key] as? Date { return date }
            if let n = (dict[key] as? NSNumber)?.doubleValue {
                if n > 1e11 { return Date(timeIntervalSince1970: n / 1000) }
                if n > 1e9 { return Date(timeIntervalSince1970: n) }
                return Date(timeIntervalSinceReferenceDate: n)
            }
        }
        return nil
    }

    // MARK: - The line

    /// The three coordinates nearest `watch`, from LocalStorage.db and both caches, leaving
    /// out the Watch's own record. `person` maps a normalized DSID to its number in the block.
    nonisolated static func nearestLine(to watch: [String: Any], label: String, stored: [StoredLocation],
                                        devices: [[String: Any]], items: [[String: Any]],
                                        person: [String: Int], now: Date) -> String? {
        guard let fix = CacheDecryptor.positionSource(for: watch),
              let lat = fix["latitude"] as? Double, let lon = fix["longitude"] as? Double else { return nil }
        let watchID = CacheDecryptor.resolveID(watch)

        var candidates: [(meters: Double, text: String)] = stored.map { location in
            let name = location.dsid.flatMap { person[$0.normalized()] }
                .map { "person \($0)'s record (\(location.source))" } ?? location.source
            let when = location.time.map { ", \(age(seconds: now.timeIntervalSince($0)))" } ?? ""
            return (meters((lat, lon), (location.latitude, location.longitude)), name + when)
        }
        for (file, records) in [("Devices.data", devices), ("Items.data", items)] {
            for record in records where CacheDecryptor.resolveID(record) != watchID || watchID == nil {
                guard let position = CacheDecryptor.positionSource(for: record),
                      let rLat = position["latitude"] as? Double, let rLon = position["longitude"] as? Double
                else { continue }
                let owner: String
                switch (record["prsId"] as? String).nonNullish {
                case "owner": owner = "this account"
                case let prsId?: owner = person[prsId.normalized()].map { "person \($0)" } ?? "not in the family"
                case nil: owner = "no person"
                }
                let what = file == "Items.data" ? "item" : deviceClass(record)
                candidates.append((meters((lat, lon), (rLat, rLon)), "\(file) \(what), \(owner)"))
            }
        }
        let nearest = candidates.sorted { $0.meters < $1.meters }.prefix(3)
            .map { "\(distanceDescription($0.meters)) \($0.text)" }
        return "    near \(label): " + (nearest.isEmpty ? "nothing else located" : nearest.joined(separator: "; "))
    }
}
