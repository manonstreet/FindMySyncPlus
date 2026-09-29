import Foundation
import SQLite3

/// Opens a SQLite database from bytes, in memory and read-only, so nothing decrypted is
/// written to disk.
enum InMemorySQLite {
    struct Failure: Error {
        let message: String
    }

    /// A connection the caller closes with `sqlite3_close`.
    static func open(_ bytes: Data) -> Result<OpaquePointer, Failure> {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(":memory:", &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let db = handle else {
            sqlite3_close(handle)
            return .failure(Failure(message: "could not open an in-memory database"))
        }
        var image = bytes
        // Bytes 18 and 19 are the read and write format versions; 2 means WAL, which an
        // in-memory database cannot use. These bytes already have the WAL merged in.
        if image.count > 19 {
            image[image.startIndex + 18] = 1
            image[image.startIndex + 19] = 1
        }
        let size = image.count
        guard size > 0,
              let buffer = sqlite3_malloc64(sqlite3_uint64(size))?.assumingMemoryBound(to: UInt8.self) else {
            sqlite3_close(db)
            return .failure(Failure(message: "could not allocate \(size) bytes"))
        }
        image.copyBytes(to: buffer, count: size)
        // FREEONCLOSE hands the buffer to SQLite, which frees it on close or on failure.
        let flags = UInt32(SQLITE_DESERIALIZE_FREEONCLOSE | SQLITE_DESERIALIZE_READONLY)
        guard sqlite3_deserialize(db, "main", buffer, sqlite3_int64(size), sqlite3_int64(size), flags) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            return .failure(Failure(message: "deserialize failed: \(message)"))
        }
        return .success(db)
    }
}
