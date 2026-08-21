import Foundation
import CommonCrypto
import SQLite3

enum LocalStorageDecryptorError: LocalizedError {
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

actor LocalStorageDecryptor {

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

    func readFriendLocations(logger: LogStore) -> Result<[DevicePoint], LocalStorageDecryptorError> {
        guard let key else { return .failure(.keyNotLoaded) }

        let home = ReadRoot.url
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
            if error.isPermissionDenied {
                return .failure(.fdaRequired)
            }
            return .failure(.dbCorrupted(error.localizedDescription))
        }

        let pageCount = dbData.count / Self.pageSize
        guard pageCount > 0 else { return .failure(.dbCorrupted("DB file is empty")) }

        // Parse WAL if present
        let wal = parseWAL(walURL)

        // Build encrypted page array, merging WAL overrides on top.
        let basePages: [Data] = (0..<pageCount).map { i in
            let start = i * Self.pageSize
            return Data(dbData[start..<start + Self.pageSize])
        }
        let (encPages, droppedOutOfRange) = mergeWALPages(basePages: basePages, walPages: wal.pages)

        // Report anything the frame guards discarded. Without this the guards are invisible:
        // a drop that goes too far reaches the user as ".incorrectKey", which is misleading.
        if wal.hasAnomalies || droppedOutOfRange > 0 {
            var reasons: [String] = []
            if let frame = wal.haltedAtSaltMismatch {
                reasons.append("halted at frame \(frame) of \(wal.frameCount) on a salt mismatch (stale WAL generation)")
            }
            if wal.droppedAfterLastCommit > 0 {
                reasons.append("\(wal.droppedAfterLastCommit) page(s) dropped as uncommitted")
            }
            if wal.invalidPageNumbers > 0 {
                reasons.append("\(wal.invalidPageNumbers) frame(s) with an invalid page number")
            }
            if droppedOutOfRange > 0 {
                reasons.append("\(droppedOutOfRange) page(s) beyond the page ceiling")
            }
            let detail = reasons.joined(separator: "; ")
            Task { @MainActor in
                logger.warn("Friends: WAL validation discarded data — \(detail). Friend locations may be stale or incomplete this cycle.")
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

        let ccStatus = keystream.withUnsafeMutableBytes { ksBuf in
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
        assert(ccStatus == kCCSuccess, "CCCrypt failed with status \(ccStatus)")

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

    /// Outcome of parsing a WAL, including why frames were discarded.
    ///
    /// The counts matter because discarding is silent by design. If the guards discard too
    /// much, the reconstructed DB fails its magic-byte check and the user is told the
    /// LocalStorage key is incorrect — which is wrong and unactionable. These let the caller
    /// say what actually happened.
    struct WALParseResult {
        var pages: [Int: Data] = [:]
        /// Total complete frames present in the file, before any validation.
        var frameCount = 0
        /// Frame index where a salt mismatch halted parsing, if any.
        var haltedAtSaltMismatch: Int?
        /// Pages discarded because the frame that last wrote them was never committed.
        var droppedAfterLastCommit = 0
        /// Frames whose page number was 0 (invalid — page numbers are 1-based).
        var invalidPageNumbers = 0

        var hasAnomalies: Bool {
            haltedAtSaltMismatch != nil || droppedAfterLastCommit > 0 || invalidPageNumbers > 0
        }
    }

    /// Parse WAL bytes and return {0-based page index: encrypted page data} plus diagnostics.
    ///
    /// Only frames up to and including the last commit frame are returned. SQLite may leave
    /// frames from an in-flight transaction at the tail of the WAL; replaying them would
    /// reconstruct a torn state that was never committed.
    ///
    /// Two passes: the first reads only 24-byte frame headers to decide which frames win,
    /// the second copies just those pages. A single pass would copy a 4 KB page per frame —
    /// on a real WAL that is hundreds of copies to keep two of them.
    nonisolated func parseWALFrames(_ walData: Data) -> WALParseResult {
        let walHeaderSize = 32
        let frameHeaderSize = 24
        let frameSize = frameHeaderSize + Self.pageSize
        guard walData.count > walHeaderSize else { return WALParseResult() }

        let base = walData.startIndex
        var result = WALParseResult()
        result.frameCount = (walData.count - walHeaderSize) / frameSize

        // Salts identify the WAL generation. A checkpoint restarts the WAL with new salts
        // but leaves old frames in place, so frames that don't match belong to a dead
        // generation and must not be replayed.
        let headerSalt1 = readBE32(walData, at: base + 16)
        let headerSalt2 = readBE32(walData, at: base + 20)

        // Pass 1 — headers only: which frame last wrote each page, and where the last commit is.
        var winningFrame: [Int: Int] = [:]
        var lastCommitFrame = -1

        for i in 0..<result.frameCount {
            let offset = walHeaderSize + i * frameSize
            guard base + offset + frameSize <= walData.endIndex else { break }

            let pgno = readBE32(walData, at: base + offset)
            let dbSizeAfterCommit = readBE32(walData, at: base + offset + 4)
            let frameSalt1 = readBE32(walData, at: base + offset + 8)
            let frameSalt2 = readBE32(walData, at: base + offset + 12)

            // Halt rather than skip: the valid region is a contiguous run from the header,
            // so nothing after a mismatch can be trusted to belong to this generation.
            guard frameSalt1 == headerSalt1, frameSalt2 == headerSalt2 else {
                result.haltedAtSaltMismatch = i
                break
            }

            // Page numbers are 1-based; 0 is invalid and would yield index -1.
            guard pgno > 0 else {
                result.invalidPageNumbers += 1
                continue
            }

            winningFrame[Int(pgno) - 1] = i

            // A non-zero db-size-after-commit marks a commit frame: everything up to and
            // including it is durable.
            if dbSizeAfterCommit != 0 { lastCommitFrame = i }
        }

        // Pass 2 — copy only the pages whose winning frame is committed.
        for (pageIndex, frameIndex) in winningFrame {
            guard frameIndex <= lastCommitFrame else {
                result.droppedAfterLastCommit += 1
                continue
            }
            let dataStart = base + walHeaderSize + frameIndex * frameSize + frameHeaderSize
            result.pages[pageIndex] = Data(walData[dataStart..<dataStart + Self.pageSize])
        }

        return result
    }

    private nonisolated func readBE32(_ data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes { buf in
            buf.loadUnaligned(fromByteOffset: offset - data.startIndex, as: UInt32.self).bigEndian
        }
    }

    /// Overlay WAL pages onto the base page array, extending it when frames land past EOF.
    ///
    /// LocalStorage.db is often a single page with the live content still in the WAL, so the
    /// array must grow. The ceiling keeps that growth bounded: a WAL cannot legitimately add
    /// more pages than it has frames, so a garbage `pgno` is dropped rather than driving the
    /// append loop toward terabytes. Sorting keeps growth strictly append-forward, since
    /// `Dictionary` iteration order is nondeterministic.
    nonisolated func mergeWALPages(
        basePages: [Data],
        walPages: [Int: Data]
    ) -> (pages: [Data], droppedOutOfRange: Int) {
        var pages = basePages
        let maxPages = basePages.count + walPages.count
        var droppedOutOfRange = 0

        for (idx, pageData) in walPages.sorted(by: { $0.key < $1.key }) {
            guard idx >= 0, idx < maxPages else {
                droppedOutOfRange += 1
                continue
            }
            while idx >= pages.count {
                pages.append(Data(count: Self.pageSize))
            }
            pages[idx] = pageData
        }
        return (pages, droppedOutOfRange)
    }

    /// Read the WAL file and parse it. A missing WAL is normal — the DB may simply be
    /// fully checkpointed, so that case is not an anomaly.
    nonisolated func parseWAL(_ walURL: URL) -> WALParseResult {
        guard let walData = try? Data(contentsOf: walURL) else { return WALParseResult() }
        return parseWALFrames(walData)
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

    private nonisolated func queryFriends(dbPath: URL, logger: LogStore) -> Result<[DevicePoint], LocalStorageDecryptorError> {
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

            // Extract rich location attributes from the bplist blob
            let richTimestamp: Date? = {
                if let ts = locDict["timestamp"] as? Double {
                    // NSDate reference date (2001-01-01) encoded as TimeInterval
                    return Date(timeIntervalSinceReferenceDate: ts)
                }
                return nil
            }()
            let rich = RichLocationAttributes(
                verticalAccuracy: locDict["verticalAccuracy"] as? Double,
                altitude: locDict["altitude"] as? Double,
                speed: locDict["speed"] as? Double,
                course: locDict["course"] as? Double,
                timestamp: richTimestamp,
                motionActivityState: {
                    guard let s = locDict["motionActivityState"] as? Int, s != 0 else { return nil }
                    return s
                }(),
                locationLabel: {
                    guard let s = locDict["locationLabel"] as? String, s != "$null" else { return nil }
                    return RichLocationAttributes.decodeLocationLabel(s)
                }()
            )

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
                battery: nil,
                richAttributes: rich
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
