import Foundation
import SQLite3
import Testing
@testable import FindMySyncPlus

/// `diag/person-location`: the person diagnostic reads the measured shapes and says nothing
/// that identifies anyone — its output is meant to be pasted on a public issue.
struct PersonLocationDiagnosticsTests {

    private static let dsid = "1A2B3C4D5E"
    private static let phoneID = "0F1E2D3C-4B5A-4697-8899-AABBCCDDEE01"
    private static let watchID = "0F1E2D3C-4B5A-4697-8899-AABBCCDDEE02"
    private static let ownerPhoneID = "0F1E2D3C-4B5A-4697-8899-AABBCCDDEE03"
    private static let now = Date()

    /// The `secureLocations.value` plist as measured on macOS 27: fourteen keys, `timestamp`
    /// a Date. `timestamp` is replaceable so the older, Double shape can be tried.
    private static func locationValue(latitude: Double = AppleRecordFixture.latitude,
                                      timestamp: Any = now.addingTimeInterval(-75)) -> [String: Any] {
        ["altitude": 32.0, "course": -1.0, "horizontalAccuracy": 12.0, "latitude": latitude,
         "longitude": AppleRecordFixture.longitude, "speed": -1.0, "verticalAccuracy": 6.0,
         "motionActivityState": 0, "publishReason": 6, "findMyId": dsid, "floor": "$null",
         "locationLabel": "$null", "locationLabelId": "$null", "timestamp": timestamp]
    }

    private struct OwnerRow { let id: String, name: String, active: Int }

    /// A database with the three tables the diagnostic reads, as file bytes.
    private func database(locations: [String: [String: Any]],
                          devicesRows: [OwnerRow]? = []) throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("person-diag-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        var schema = "CREATE TABLE secureLocations (serverUserID TEXT, value BLOB);"
        if devicesRows != nil {
            schema += """
                CREATE TABLE devices (deviceIdentifier TEXT, idsDeviceId TEXT, deviceName TEXT,
                    deviceIsActive INTEGER, isThisDevice INTEGER, deviceIsCompanion INTEGER,
                    deviceIsAutoMeCapable INTEGER, isInQuickSwitchCircle INTEGER);
                CREATE TABLE autoMeCapableWatches (deviceIdentifier TEXT);
                INSERT INTO autoMeCapableWatches VALUES ('w');
                """
        }
        try #require(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (server, value) in locations {
            let blob = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
            var stmt: OpaquePointer?
            try #require(sqlite3_prepare_v2(db, "INSERT INTO secureLocations VALUES (?, ?)", -1, &stmt, nil) == SQLITE_OK)
            sqlite3_bind_text(stmt, 1, server, -1, transient)
            _ = blob.withUnsafeBytes { sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32(blob.count), transient) }
            try #require(sqlite3_step(stmt) == SQLITE_DONE)
            sqlite3_finalize(stmt)
        }
        for row in devicesRows ?? [] {
            try #require(sqlite3_exec(db, "INSERT INTO devices VALUES ('\(row.id)', NULL, '\(row.name)', "
                                      + "\(row.active), 0, 0, 1, 1)", nil, nil, nil) == SQLITE_OK)
        }
        sqlite3_close(db)
        return try Data(contentsOf: url)
    }

    private static func familyDevice(_ cls: String, id: String, location: [String: Any]?) -> [String: Any] {
        var record = AppleRecordFixture.device(name: "Test \(cls)", baUUID: id, location: location, prsId: dsid)
        record["deviceClass"] = cls
        return record
    }

    // MARK: - Reading

    @Test func theMeasuredRecordIsRead() throws {
        let snapshot = PersonLocationDiagnostics.snapshot(database: try database(
            locations: [Self.dsid: Self.locationValue()],
            devicesRows: [OwnerRow(id: Self.ownerPhoneID, name: "Test iPhone", active: 1)]))
        let person = try #require(snapshot.people.first)
        #expect(person.timestampType == "Date")
        #expect(abs(try #require(person.timestamp).timeIntervalSince(Self.now) + 75) < 1)
        #expect(person.publishReason == "6")
        #expect(person.motionActivityState == "0")
        #expect(snapshot.ownerDevices?.first?.flags["deviceIsActive"] == "1")
        #expect(snapshot.autoMeCapableWatches == 1)
        #expect(snapshot.problems.isEmpty)
    }

    /// The app reads friends' `timestamp` as a Double. The diagnostic takes either
    /// and says which it found, so a requester on another macOS shows us their shape.
    @Test func aDoubleTimestampIsReadAndNamed() throws {
        let seconds = Self.now.addingTimeInterval(-300).timeIntervalSinceReferenceDate
        let snapshot = PersonLocationDiagnostics.snapshot(database: try database(
            locations: [Self.dsid: Self.locationValue(timestamp: seconds)]))
        let person = try #require(snapshot.people.first)
        #expect(person.timestampType == "Double")
        #expect(abs(try #require(person.timestamp).timeIntervalSinceReferenceDate - seconds) < 1)
    }

    @Test func aMissingDevicesTableIsReportedNotHidden() throws {
        let snapshot = PersonLocationDiagnostics.snapshot(database: try database(
            locations: [Self.dsid: Self.locationValue()], devicesRows: nil))
        #expect(snapshot.ownerDevices == nil)
        #expect(snapshot.problems == ["no devices table"])
        let lines = PersonLocationDiagnostics.block(snapshot: snapshot, devices: [], now: Self.now)
        #expect(lines.contains("problem: no devices table"))
    }

    // MARK: - The block

    @Test func eachDeviceIsPlacedAgainstThePersonRecord() throws {
        let snapshot = PersonLocationDiagnostics.snapshot(database: try database(
            locations: [Self.dsid: Self.locationValue()],
            devicesRows: [OwnerRow(id: Self.ownerPhoneID, name: "Owner Phone", active: 1)]))
        // About 6.7 km north of the record, the shape of a Watch left at home.
        let devices = [
            Self.familyDevice("iPhone", id: Self.phoneID,
                              location: AppleRecordFixture.location(accuracy: 9, ageMinutes: 5, positionType: "GPS")),
            Self.familyDevice("Watch", id: Self.watchID,
                              location: AppleRecordFixture.location(latitude: AppleRecordFixture.latitude + 0.06,
                                                                    ageMinutes: 79)),
            Self.familyDevice("iPad", id: "0F1E2D3C-4B5A-4697-8899-AABBCCDDEE04", location: nil),
            AppleRecordFixture.device(name: "Owner Phone", baUUID: Self.ownerPhoneID)
                .merging(["deviceClass": "iPhone"]) { $1 }
        ]

        let lines = PersonLocationDiagnostics.block(snapshot: snapshot, devices: devices, now: Self.now)

        #expect(lines.first == "person 1: record 75 s old, ±12 m, publishReason 6, motionActivityState 0, "
                + "timestamp stored as Date")
        #expect(lines.contains("    iPhone: 0 m from the record, fix 5 min old, ±9 m, GPS"))
        #expect(lines.contains("    Watch: 6.7 km from the record, fix 79 min old, ±15 m, Wifi"))
        #expect(lines.contains("    plus 1 with no location: iPad"))
        #expect(lines.contains("owner: 1 devices row(s), 1 active; autoMeCapableWatches 1"))
        #expect(lines.contains("    active: iPhone (matched on `deviceDiscoveryId`) — deviceIsActive=1 isThisDevice=0 "
                               + "deviceIsCompanion=0 deviceIsAutoMeCapable=1 isInQuickSwitchCircle=1"))
    }

    /// The point of the block: it can be pasted publicly as it stands.
    @Test func nothingIdentifyingReachesTheBlock() throws {
        let snapshot = PersonLocationDiagnostics.snapshot(database: try database(
            locations: [Self.dsid: Self.locationValue(), "FFEE0011": Self.locationValue()],
            devicesRows: [OwnerRow(id: Self.ownerPhoneID, name: "Owner Phone", active: 1)]))
        let devices = [
            Self.familyDevice("iPhone", id: Self.phoneID, location: AppleRecordFixture.location()),
            AppleRecordFixture.device(name: "Owner Phone", baUUID: Self.ownerPhoneID)
        ]
        let text = PersonLocationDiagnostics.block(snapshot: snapshot, devices: devices, now: Self.now)
            .joined(separator: "\n")

        for secret in [Self.dsid, "FFEE0011", Self.phoneID, Self.ownerPhoneID, "Owner Phone", "Test iPhone",
                       "37.33", "122.0"] {
            #expect(!text.contains(secret), "the block leaked \(secret)")
        }
        #expect(text.contains("1 more person record(s) with no devices here"))
    }

    @Test func twoDevicesOfOneClassAreNumberedAndTheUnlocatedShareALine() throws {
        let snapshot = PersonLocationDiagnostics.snapshot(database: try database(locations: [:]))
        let devices = [Self.familyDevice("iPhone", id: Self.phoneID, location: nil),
                       Self.familyDevice("iPhone", id: Self.watchID, location: nil)]
        let lines = PersonLocationDiagnostics.block(snapshot: snapshot, devices: devices, now: Self.now)
        #expect(lines.prefix(2) == ["person 1: no person record — not sharing a location with this account",
                                    "    plus 2 with no location: iPhone, iPhone 2"])
    }

    /// A long run keeps the recent window, and the file says what it dropped.
    @MainActor @Test func theKeptBlocksAreCappedAndTheDropIsReported() {
        let log = PersonDiagnosticsLog()
        for n in 0..<(PersonDiagnosticsLog.cap + 5) { log.append(["sync \(n)"], at: Self.now) }
        #expect(log.blocks.count == PersonDiagnosticsLog.cap)
        #expect(log.blocks.first?.lines == ["sync 5"])
        #expect(log.plainText(syncIntervalSeconds: 60).contains("\(PersonDiagnosticsLog.cap) sync(s), 5 older dropped"))
    }

    @Test func noSnapshotSaysSo() {
        #expect(PersonLocationDiagnostics.block(snapshot: nil, devices: nil, now: Self.now)
                == ["no LocalStorage.db snapshot this sync — the Friends lines above say why"])
    }

    @Test func agesReadAsPeopleSayThem() {
        #expect(PersonLocationDiagnostics.age(seconds: 75) == "75 s old")
        #expect(PersonLocationDiagnostics.age(seconds: 300) == "5 min old")
        #expect(PersonLocationDiagnostics.age(seconds: 4 * 3600) == "4.0 h old")
        #expect(PersonLocationDiagnostics.age(seconds: -30) == "-30 s old")
    }
}
