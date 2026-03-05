import Foundation
import CommonCrypto
import SQLite3

enum FriendDecryptorError: LocalizedError {
    case fdaRequired
    case keyNotLoaded
    case incorrectKey
    case dbNotFound
    case dbCorrupted(String)
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .fdaRequired:
            return "Full Disk Access is required to read the Find My friend database."
        case .keyNotLoaded:
            return "LocalStorage decryption key is not loaded in memory."
        case .incorrectKey:
            return "LocalStorage key is incorrect: decrypted page 0 does not contain SQLite magic."
        case .dbNotFound:
            return "LocalStorage.db not found. Ensure Find My has been opened at least once."
        case .dbCorrupted(let detail):
            return "LocalStorage.db appears corrupted: \(detail)"
        case .queryFailed(let detail):
            return "Friend location query failed: \(detail)"
        }
    }
}

actor FriendDecryptor {

    private var key: Data?

    // MARK: - Key management

    func ensureKey(logger: LogStore) {
        guard key == nil else { return }
        if let raw = Keychain.getData(for: .localStorageKey) {
            guard raw.count == 32 else {
                Task { @MainActor in logger.error("LocalStorage key has unexpected length: \(raw.count) bytes; expected 32. Please re-import.") }
                return
            }
            key = raw
            Task { @MainActor in logger.info("LocalStorage key loaded from Keychain (\(raw.count) bytes)") }
        } else {
            Task { @MainActor in logger.debug("LocalStorage key not found in Keychain.") }
        }
    }

    func invalidateKey() { key = nil }

    // MARK: - Constants

    private static let pageSize = 4096
    private static let contentSize = 4084       // encrypted content per page
    private static let reservedOffset = 4084    // start of 12-byte reserved area
    private static let reservedSize = 12
    private static let sqliteMagic = Data("SQLite format 3\0".utf8)

    private static let dbRelativePath = "Library/Group Containers/group.com.apple.findmy.findmylocateagent/Library/Application Support/LocalStorage.db"
    private static let walRelativePath = dbRelativePath + "-wal"

    // MARK: - Public API

    func readFriendLocations(logger: LogStore) -> Result<[DevicePoint], FriendDecryptorError> {
        guard let key else { return .failure(.keyNotLoaded) }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let dbURL = home.appendingPathComponent(Self.dbRelativePath)
        let walURL = home.appendingPathComponent(Self.walRelativePath)

        // Read encrypted DB
        let dbData: Data
        do {
            dbData = try Data(contentsOf: dbURL)
        } catch {
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoSuchFileError {
                return .failure(.dbNotFound)
            }
            let permissionDenied = (ns.domain == NSCocoaErrorDomain && ns.code == 257)
                || error.localizedDescription.localizedCaseInsensitiveContains("operation not permitted")
                || error.localizedDescription.localizedCaseInsensitiveContains("permission")
            if permissionDenied {
                return .failure(.fdaRequired)
            }
            return .failure(.dbCorrupted(error.localizedDescription))
        }

        let pageCount = dbData.count / Self.pageSize
        guard pageCount > 0 else { return .failure(.dbCorrupted("DB file is empty")) }

        // Parse WAL if present
        let walPages = parseWAL(walURL)

        // Build encrypted page array, merging WAL overrides
        var encPages: [Data] = (0..<pageCount).map { i in
            let start = i * Self.pageSize
            return Data(dbData[start..<start + Self.pageSize])
        }
        for (idx, pageData) in walPages {
            if idx < encPages.count {
                encPages[idx] = pageData
            }
        }

        // Verify key by decrypting page 0
        let page0 = decryptPage(encPages[0], pageIndex: 0, key: key)
        guard page0.prefix(16) == Self.sqliteMagic else {
            return .failure(.incorrectKey)
        }

        // Decrypt all pages and build the SQLite file
        let decryptedDB = buildDecryptedDB(encPages: encPages, key: key)

        // Write to temp file and query
        let tmpURL: URL
        do {
            let tmpDir = FileManager.default.temporaryDirectory
            tmpURL = tmpDir.appendingPathComponent("fms_friends_\(ProcessInfo.processInfo.globallyUniqueString).db")
            try decryptedDB.write(to: tmpURL)
        } catch {
            return .failure(.dbCorrupted("Failed to write temp DB: \(error.localizedDescription)"))
        }
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        return queryFriends(dbPath: tmpURL, logger: logger)
    }

    // MARK: - Crypto

    /// Decrypt one 4096-byte encrypted page using Apple's sqliteCodecCCCrypto scheme.
    ///
    /// IV = pgno_LE32(4) + reserved(12)  where pgno is 1-indexed.
    /// keystream = AES_CBC_ENCRYPT(key, IV, zeros[4096])
    /// plaintext = enc[0:4084] XOR keystream[0:4084]
    /// Page 0: bytes 16-23 stored plaintext (header constants) -- restore after XOR.
    nonisolated func decryptPage(_ encPage: Data, pageIndex: Int, key: Data) -> Data {
        let pgno = UInt32(pageIndex + 1)  // 1-indexed

        // Build IV: pgno as little-endian 4 bytes + 12 reserved bytes
        var iv = Data(count: 16)
        withUnsafeBytes(of: pgno.littleEndian) { iv.replaceSubrange(0..<4, with: $0) }
        let reservedStart = Self.reservedOffset
        iv.replaceSubrange(4..<16, with: encPage[reservedStart..<reservedStart + Self.reservedSize])

        // Generate keystream: AES-256-CBC encrypt zeros
        let zeros = Data(count: Self.pageSize)
        var keystream = Data(count: Self.pageSize + kCCBlockSizeAES128)
        var keystreamLen = 0

        _ = keystream.withUnsafeMutableBytes { ksBuf in
            iv.withUnsafeBytes { ivBuf in
                key.withUnsafeBytes { keyBuf in
                    zeros.withUnsafeBytes { zBuf in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            0,  // no padding
                            keyBuf.baseAddress, key.count,
                            ivBuf.baseAddress,
                            zBuf.baseAddress, Self.pageSize,
                            ksBuf.baseAddress, ksBuf.count,
                            &keystreamLen
                        )
                    }
                }
            }
        }

        // XOR encrypted content with keystream
        var plaintext = Data(count: Self.contentSize)
        encPage.withUnsafeBytes { encBuf in
            keystream.withUnsafeBytes { ksBuf in
                let enc = encBuf.bindMemory(to: UInt8.self)
                let ks = ksBuf.bindMemory(to: UInt8.self)
                plaintext.withUnsafeMutableBytes { ptBuf in
                    let pt = ptBuf.bindMemory(to: UInt8.self)
                    for i in 0..<Self.contentSize {
                        pt[i] = enc[i] ^ ks[i]
                    }
                }
            }
        }

        // Page 0 fix-up: bytes 16-23 are stored plaintext in the encrypted page
        if pageIndex == 0 {
            plaintext.replaceSubrange(16..<24, with: encPage[16..<24])
        }

        return plaintext
    }

    // MARK: - WAL parsing

    /// Parse WAL file and return {0-based page index: encrypted page data}, keeping latest frame per page.
    private nonisolated func parseWAL(_ walURL: URL) -> [Int: Data] {
        guard let walData = try? Data(contentsOf: walURL) else { return [:] }
        let walHeaderSize = 32
        let frameHeaderSize = 24
        let frameSize = frameHeaderSize + Self.pageSize
        guard walData.count > walHeaderSize else { return [:] }

        let frameCount = (walData.count - walHeaderSize) / frameSize
        var pages: [Int: Data] = [:]

        for i in 0..<frameCount {
            let offset = walHeaderSize + i * frameSize
            guard offset + 4 <= walData.count else { break }
            // Page number is 1-indexed, big-endian in WAL header
            let pgno = walData.withUnsafeBytes { buf in
                buf.load(fromByteOffset: offset, as: UInt32.self).bigEndian
            }
            let dataStart = offset + frameHeaderSize
            let dataEnd = dataStart + Self.pageSize
            guard dataEnd <= walData.count else { break }
            pages[Int(pgno) - 1] = Data(walData[dataStart..<dataEnd])  // convert to 0-indexed
        }
        return pages
    }

    // MARK: - DB reconstruction

    /// Decrypt all pages and reconstruct a complete SQLite file (content + reserved areas).
    private nonisolated func buildDecryptedDB(encPages: [Data], key: Data) -> Data {
        var result = Data()
        result.reserveCapacity(encPages.count * Self.pageSize)

        for (i, enc) in encPages.enumerated() {
            let plain = decryptPage(enc, pageIndex: i, key: key)                          // 4084 bytes
            let reserved = Data(enc[Self.reservedOffset..<Self.reservedOffset + Self.reservedSize]) // 12 bytes
            result.append(plain)
            result.append(reserved)
        }
        return result
    }

    // MARK: - SQLite query

    private nonisolated func queryFriends(dbPath: URL, logger: LogStore) -> Result<[DevicePoint], FriendDecryptorError> {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            return .failure(.queryFailed("sqlite3_open failed: \(msg)"))
        }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT
                f.handlePrettyName,
                f.handleContactIdentifier,
                f.handleIdentifier,
                f.handleServerIdentifier,
                f.types,
                sl.value
            FROM friends f
            JOIN secureLocations sl
              ON f.handleServerIdentifier = sl.serverUserID
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            return .failure(.queryFailed("prepare failed: \(msg)"))
        }
        defer { sqlite3_finalize(stmt) }

        var results: [DevicePoint] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let prettyName = columnText(stmt, 0)
            let contactId = columnText(stmt, 1)
            let handleId = columnText(stmt, 2)
            let serverIdentifier = columnText(stmt, 3)
            let types = columnText(stmt, 4)

            guard let serverIdentifier, !serverIdentifier.isEmpty else { continue }

            // Parse location from plist blob
            guard let blobPtr = sqlite3_column_blob(stmt, 5) else { continue }
            let blobLen = Int(sqlite3_column_bytes(stmt, 5))
            guard blobLen > 0 else { continue }
            let blobData = Data(bytes: blobPtr, count: blobLen)

            guard let locDict = try? PropertyListSerialization.propertyList(from: blobData, options: [], format: nil) as? [String: Any] else { continue }

            guard let lat = locDict["latitude"] as? Double,
                  let lon = locDict["longitude"] as? Double else { continue }

            let acc = (locDict["horizontalAccuracy"] as? Double) ?? 0

            let name = prettyName ?? contactId ?? handleId ?? "(unknown)"

            // Log types field at debug level for investigation
            Task { @MainActor in
                logger.debug("Friend \"\(name)\" serverID=\(serverIdentifier) types=\(types ?? "nil")")
            }

            results.append(DevicePoint(
                id: serverIdentifier,
                name: name,
                latitude: lat,
                longitude: lon,
                accuracy: acc,
                battery: nil
            ))
        }

        return .success(results)
    }

    // MARK: - SQLite helpers

    private nonisolated func columnText(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        guard let cStr = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: cStr)
    }

    // MARK: - Testing support

    #if DEBUG
    func loadKeyForTesting(_ testKey: Data) {
        key = testKey
    }
    #endif
}
