import Foundation
import SQLite3
import Testing
@testable import FindMySyncPlus

/// The friends query, run against a database opened in memory from a WAL-mode file's bytes.
struct FriendsDatabaseTests {

    private struct Friend {
        let server: String
        let name: String
        let location: [String: Any]
    }

    /// A database with the two tables the query reads, in WAL mode, returned as its file bytes.
    private func walDatabase(friends: [Friend]) throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("friends-test-\(UUID().uuidString).db")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        let schema = """
            PRAGMA journal_mode=WAL;
            CREATE TABLE friends (handlePrettyName TEXT, handleContactIdentifier TEXT,
                                  handleIdentifier TEXT, handleServerIdentifier TEXT, types TEXT);
            CREATE TABLE secureLocations (serverUserID TEXT, value BLOB);
            """
        try #require(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for friend in friends {
            let blob = try PropertyListSerialization.data(fromPropertyList: friend.location,
                                                          format: .binary, options: 0)
            var stmt: OpaquePointer?
            try #require(sqlite3_exec(db, "INSERT INTO friends VALUES ('\(friend.name)', NULL, NULL, "
                                      + "'\(friend.server)', NULL)", nil, nil, nil) == SQLITE_OK)
            try #require(sqlite3_prepare_v2(db, "INSERT INTO secureLocations VALUES (?, ?)", -1, &stmt, nil)
                         == SQLITE_OK)
            sqlite3_bind_text(stmt, 1, friend.server, -1, transient)
            _ = blob.withUnsafeBytes { sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32(blob.count), transient) }
            try #require(sqlite3_step(stmt) == SQLITE_DONE)
            sqlite3_finalize(stmt)
        }
        try #require(sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        return try Data(contentsOf: url)
    }

    @Test func aWALModeDatabaseIsReadFromMemory() throws {
        let bytes = try walDatabase(friends: [
            Friend(server: "S1", name: "Test Friend", location: ["latitude": 51.5, "longitude": -0.1, "horizontalAccuracy": 12.0])
        ])
        #expect(bytes[18] == 2, "the fixture must carry the WAL header the in-memory open has to handle")

        let friends = try LocalStorageDecryptor().queryFriends(database: bytes, logger: LogStore()).get()
        #expect(friends.count == 1)
        #expect(friends.first?.latitude == 51.5)
        #expect(friends.first?.accuracy == 12.0)
    }

    @Test func aPositionWithNoAccuracyKeepsNoAccuracy() throws {
        let bytes = try walDatabase(friends: [
            Friend(server: "S2", name: "Test Friend", location: ["latitude": 48.8, "longitude": 2.3])
        ])
        let friends = try LocalStorageDecryptor().queryFriends(database: bytes, logger: LogStore()).get()
        #expect(friends.count == 1)
        #expect(friends.first?.accuracy == nil)
    }

    @Test func bytesThatAreNotADatabaseFailWithAReason() {
        guard case .failure = LocalStorageDecryptor().queryFriends(database: Data("junk".utf8), logger: LogStore()) else {
            Issue.record("expected a failure")
            return
        }
    }
}
