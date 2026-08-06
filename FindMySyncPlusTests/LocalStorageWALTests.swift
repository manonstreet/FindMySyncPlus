import Testing
import Foundation
@testable import FindMySyncPlus

// MARK: - Synthetic WAL construction

/// A single WAL frame to be serialized by `makeWAL`.
///
/// Mirrors the SQLite WAL frame header layout:
/// pgno(4) | dbSizeAfterCommit(4) | salt1(4) | salt2(4) | checksum1(4) | checksum2(4)
private struct WALFrame {
    var pgno: UInt32
    /// Database size in pages after this commit. 0 means "not a commit frame".
    var dbSizeAfterCommit: UInt32 = 0
    var salt1: UInt32
    var salt2: UInt32
    /// Byte the 4096-byte page body is filled with, so tests can assert which frame won.
    var fill: UInt8
}

private let walPageSize = 4096

private func beBytes(_ value: UInt32) -> Data {
    withUnsafeBytes(of: value.bigEndian) { Data($0) }
}

/// Build a synthetic WAL file.
///
/// WAL header layout:
/// magic(4) | version(4) | pageSize(4) | checkpointSeq(4) | salt1(4) | salt2(4) | checksum1(4) | checksum2(4)
///
/// - Parameter truncateBy: bytes to chop off the end, to simulate a torn final frame.
private func makeWAL(
    headerSalt1: UInt32 = 0xAAAA_1111,
    headerSalt2: UInt32 = 0xBBBB_2222,
    frames: [WALFrame],
    truncateBy: Int = 0
) -> Data {
    var data = Data()
    data.append(beBytes(0x377F_0682))      // magic
    data.append(beBytes(3_007_000))        // file format version
    data.append(beBytes(UInt32(walPageSize)))
    data.append(beBytes(1))                // checkpoint sequence
    data.append(beBytes(headerSalt1))
    data.append(beBytes(headerSalt2))
    data.append(beBytes(0))                // checksum1 (unverified by parser)
    data.append(beBytes(0))                // checksum2

    for frame in frames {
        data.append(beBytes(frame.pgno))
        data.append(beBytes(frame.dbSizeAfterCommit))
        data.append(beBytes(frame.salt1))
        data.append(beBytes(frame.salt2))
        data.append(beBytes(0))            // checksum1
        data.append(beBytes(0))            // checksum2
        data.append(Data(repeating: frame.fill, count: walPageSize))
    }

    if truncateBy > 0 {
        data.removeLast(min(truncateBy, data.count))
    }
    return data
}

// MARK: - Tests

@Suite("parseWALFrames")
struct LocalStorageWALTests {

    /// Only frames up to and including the last commit frame are committed data.
    /// SQLite may leave uncommitted frames from an in-flight transaction at the tail
    /// of the WAL; replaying them yields a torn, never-committed database state.
    @Test("drops frames written after the last commit frame")
    func dropsFramesAfterLastCommit() {
        let wal = makeWAL(frames: [
            WALFrame(pgno: 1, dbSizeAfterCommit: 1, salt1: 0xAAAA_1111, salt2: 0xBBBB_2222, fill: 0xA1),
            WALFrame(pgno: 2, dbSizeAfterCommit: 0, salt1: 0xAAAA_1111, salt2: 0xBBBB_2222, fill: 0xB2)
        ])

        let pages = LocalStorageDecryptor().parseWALFrames(wal).pages

        #expect(pages[0]?.first == 0xA1)
        #expect(pages[1] == nil, "frame 2 is uncommitted and must not be replayed")
    }

    /// After a checkpoint SQLite restarts the WAL with fresh salts but leaves the old
    /// frames in the file. Those stale frames sit at *higher* offsets than the live ones,
    /// so a naive last-writer-wins merge lets stale data overwrite current data.
    @Test("ignores frames left over from a previous WAL generation")
    func ignoresStaleGenerationFrames() {
        let wal = makeWAL(frames: [
            WALFrame(pgno: 1, dbSizeAfterCommit: 1, salt1: 0xAAAA_1111, salt2: 0xBBBB_2222, fill: 0xA1),
            WALFrame(pgno: 2, dbSizeAfterCommit: 2, salt1: 0xDEAD_0000, salt2: 0xBEEF_0000, fill: 0xB2)
        ])

        let pages = LocalStorageDecryptor().parseWALFrames(wal).pages

        #expect(pages[0]?.first == 0xA1)
        #expect(pages[1] == nil, "salt mismatch marks a stale generation; the frame must be ignored")
    }

    /// The valid region of a WAL is a contiguous run from the header. Once the salts stop
    /// matching there is no way to know that later same-salt frames belong to *this*
    /// generation rather than an older one that happened to share salts, so parsing must
    /// halt rather than skip the bad frame and resume.
    @Test("stops at the first salt mismatch instead of resuming after it")
    func stopsAtFirstSaltMismatch() {
        let wal = makeWAL(frames: [
            WALFrame(pgno: 1, dbSizeAfterCommit: 1, salt1: 0xAAAA_1111, salt2: 0xBBBB_2222, fill: 0xA1),
            WALFrame(pgno: 2, dbSizeAfterCommit: 2, salt1: 0xDEAD_0000, salt2: 0xBEEF_0000, fill: 0xB2),
            WALFrame(pgno: 3, dbSizeAfterCommit: 3, salt1: 0xAAAA_1111, salt2: 0xBBBB_2222, fill: 0xC3)
        ])

        let pages = LocalStorageDecryptor().parseWALFrames(wal).pages

        #expect(pages[0]?.first == 0xA1)
        #expect(pages[2] == nil, "frames beyond the first salt mismatch must not be replayed")
    }

    /// Page numbers are 1-based, so `pgno == 0` is invalid. Converting it yields index -1,
    /// which previously flowed into the caller's page array and trapped on subscript.
    @Test("rejects frames with an invalid page number of zero")
    func rejectsZeroPageNumber() {
        let wal = makeWAL(frames: [
            WALFrame(pgno: 0, dbSizeAfterCommit: 1, salt1: 0xAAAA_1111, salt2: 0xBBBB_2222, fill: 0xA1),
            WALFrame(pgno: 1, dbSizeAfterCommit: 1, salt1: 0xAAAA_1111, salt2: 0xBBBB_2222, fill: 0xB2)
        ])

        let pages = LocalStorageDecryptor().parseWALFrames(wal).pages

        #expect(pages[-1] == nil, "pgno 0 must never produce a negative page index")
        #expect(pages[0]?.first == 0xB2, "valid frames after an invalid one are still parsed")
    }

    @Test("returns pages zero-indexed from the 1-based WAL page number")
    func returnsZeroIndexedPages() {
        let wal = makeWAL(frames: [
            WALFrame(pgno: 3, dbSizeAfterCommit: 3, salt1: 0xAAAA_1111, salt2: 0xBBBB_2222, fill: 0xC3)
        ])

        let pages = LocalStorageDecryptor().parseWALFrames(wal).pages

        #expect(pages[2]?.first == 0xC3)
        #expect(pages[3] == nil)
    }

    @Test("keeps the newest frame when a page is rewritten within one generation")
    func laterFrameWinsWithinGeneration() {
        let wal = makeWAL(frames: [
            WALFrame(pgno: 1, dbSizeAfterCommit: 1, salt1: 0xAAAA_1111, salt2: 0xBBBB_2222, fill: 0x11),
            WALFrame(pgno: 1, dbSizeAfterCommit: 1, salt1: 0xAAAA_1111, salt2: 0xBBBB_2222, fill: 0x22)
        ])

        let pages = LocalStorageDecryptor().parseWALFrames(wal).pages

        #expect(pages[0]?.first == 0x22, "the later frame supersedes the earlier one")
    }

    /// A WAL with no complete frame carries no committed data, however it is malformed.
    @Test("yields nothing for headers with no complete frame", arguments: [0, 1, 8, 31, 32])
    func yieldsNothingForHeaderOnlyInput(byteCount: Int) {
        let wal = Data(repeating: 0, count: byteCount)

        #expect(LocalStorageDecryptor().parseWALFrames(wal).pages.isEmpty)
    }

    /// A crash mid-append leaves a partial frame at the tail. It was never committed.
    @Test("ignores a torn final frame")
    func ignoresTornFinalFrame() {
        let wal = makeWAL(frames: [
            WALFrame(pgno: 1, dbSizeAfterCommit: 1, salt1: 0xAAAA_1111, salt2: 0xBBBB_2222, fill: 0xA1),
            WALFrame(pgno: 2, dbSizeAfterCommit: 2, salt1: 0xAAAA_1111, salt2: 0xBBBB_2222, fill: 0xB2)
        ], truncateBy: 100)

        let pages = LocalStorageDecryptor().parseWALFrames(wal).pages

        #expect(pages[0]?.first == 0xA1)
        #expect(pages[1] == nil, "the torn frame must not be replayed")
    }

    /// Guards the wiring: the file-reading entry point must route through the hardened
    /// parser, not keep a parallel implementation of its own.
    @Test("parseWAL applies frame validation when reading from disk")
    func parseWALFromDiskAppliesValidation() throws {
        let wal = makeWAL(frames: [
            WALFrame(pgno: 1, dbSizeAfterCommit: 1, salt1: 0xAAAA_1111, salt2: 0xBBBB_2222, fill: 0xA1),
            WALFrame(pgno: 2, dbSizeAfterCommit: 0, salt1: 0xAAAA_1111, salt2: 0xBBBB_2222, fill: 0xB2)
        ])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fms_wal_test_\(UUID().uuidString).wal")
        try wal.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let pages = LocalStorageDecryptor().parseWAL(url).pages

        #expect(pages[0]?.first == 0xA1)
        #expect(pages[1] == nil, "uncommitted frame must be dropped on the disk path too")
    }

    @Test("parseWAL returns nothing when the WAL file is absent")
    func parseWALMissingFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fms_wal_does_not_exist_\(UUID().uuidString).wal")

        #expect(LocalStorageDecryptor().parseWAL(url).pages.isEmpty)
    }
}

// MARK: - Page merge

@Suite("mergeWALPages")
struct LocalStorageWALMergeTests {

    private func page(_ fill: UInt8) -> Data { Data(repeating: fill, count: walPageSize) }

    /// The bug behind PR #15: LocalStorage.db is often a single page with the live
    /// content still in the WAL, so the merge must grow the array past EOF.
    @Test("extends the page array when a WAL frame lands beyond EOF")
    func extendsBeyondEOF() throws {
        let merged = LocalStorageDecryptor().mergeWALPages(
            basePages: [page(0x00)],
            walPages: [0: page(0xA1), 2: page(0xC3)]
        ).pages

        // `#require` rather than `#expect`: `#expect` records the failure but keeps
        // running, so a short array would trap on the subscripts below and crash the
        // whole test process, taking unrelated tests down with it.
        try #require(merged.count == 3)
        #expect(merged[0].first == 0xA1)
        #expect(merged[1].allSatisfy { $0 == 0 }, "the gap page is zero-filled")
        #expect(merged[2].first == 0xC3)
    }

    /// A garbage `pgno` must not drive unbounded appends. A WAL cannot add more pages
    /// than it has frames, so anything past that ceiling is dropped.
    @Test("drops frames beyond the page ceiling instead of growing without bound")
    func dropsOutOfRangeFrames() throws {
        let merged = LocalStorageDecryptor().mergeWALPages(
            basePages: [page(0x00)],
            walPages: [0: page(0xA1), 999_999: page(0xFF)]
        ).pages

        // The in-range frame overwrites page 0 in place and the garbage frame is dropped,
        // so the array never grows. Without the ceiling the append loop would run toward
        // index 999_999 and exhaust memory.
        try #require(merged.count == 1)
        #expect(merged[0].first == 0xA1)
    }

    @Test("leaves base pages untouched when the WAL is empty")
    func emptyWALIsIdentity() {
        let merged = LocalStorageDecryptor().mergeWALPages(
            basePages: [page(0x11), page(0x22)],
            walPages: [:]
        ).pages

        #expect(merged.map(\.first) == [0x11, 0x22])
    }
}

// MARK: - Diagnostics

/// The guards drop frames silently by design — dropping is the correct behavior. But a
/// silent drop that goes too far surfaces to the user as "LocalStorage key is incorrect",
/// which is actively misleading. These counts are what makes that distinguishable in the log.
@Suite("WAL diagnostics")
struct LocalStorageWALDiagnosticsTests {

    private let salt1: UInt32 = 0xAAAA_1111
    private let salt2: UInt32 = 0xBBBB_2222

    @Test("reports a clean WAL as having no anomalies")
    func cleanWALHasNoAnomalies() {
        let wal = makeWAL(frames: [
            WALFrame(pgno: 1, dbSizeAfterCommit: 1, salt1: salt1, salt2: salt2, fill: 0xA1)
        ])

        let result = LocalStorageDecryptor().parseWALFrames(wal)

        #expect(result.frameCount == 1)
        #expect(result.haltedAtSaltMismatch == nil)
        #expect(result.droppedAfterLastCommit == 0)
        #expect(result.invalidPageNumbers == 0)
        #expect(result.hasAnomalies == false)
    }

    @Test("reports the frame index where a salt mismatch halted parsing")
    func reportsSaltMismatchIndex() {
        let wal = makeWAL(frames: [
            WALFrame(pgno: 1, dbSizeAfterCommit: 1, salt1: salt1, salt2: salt2, fill: 0xA1),
            WALFrame(pgno: 2, dbSizeAfterCommit: 2, salt1: 0xDEAD_0000, salt2: 0xBEEF_0000, fill: 0xB2),
            WALFrame(pgno: 3, dbSizeAfterCommit: 3, salt1: 0xDEAD_0000, salt2: 0xBEEF_0000, fill: 0xC3)
        ])

        let result = LocalStorageDecryptor().parseWALFrames(wal)

        #expect(result.frameCount == 3)
        #expect(result.haltedAtSaltMismatch == 1, "halted at frame index 1")
        #expect(result.hasAnomalies)
    }

    @Test("counts frames discarded past the last commit frame")
    func countsFramesAfterLastCommit() {
        let wal = makeWAL(frames: [
            WALFrame(pgno: 1, dbSizeAfterCommit: 1, salt1: salt1, salt2: salt2, fill: 0xA1),
            WALFrame(pgno: 2, dbSizeAfterCommit: 0, salt1: salt1, salt2: salt2, fill: 0xB2),
            WALFrame(pgno: 3, dbSizeAfterCommit: 0, salt1: salt1, salt2: salt2, fill: 0xC3)
        ])

        let result = LocalStorageDecryptor().parseWALFrames(wal)

        #expect(result.droppedAfterLastCommit == 2)
        #expect(result.hasAnomalies)
    }

    @Test("counts frames carrying an invalid page number")
    func countsInvalidPageNumbers() {
        let wal = makeWAL(frames: [
            WALFrame(pgno: 0, dbSizeAfterCommit: 0, salt1: salt1, salt2: salt2, fill: 0xA1),
            WALFrame(pgno: 1, dbSizeAfterCommit: 1, salt1: salt1, salt2: salt2, fill: 0xB2)
        ])

        let result = LocalStorageDecryptor().parseWALFrames(wal)

        #expect(result.invalidPageNumbers == 1)
        #expect(result.hasAnomalies)
    }

    @Test("reports how many WAL pages fell outside the page ceiling")
    func reportsOutOfRangeMergeDrops() {
        let page = Data(repeating: 0xEE, count: walPageSize)

        let merged = LocalStorageDecryptor().mergeWALPages(
            basePages: [Data(repeating: 0, count: walPageSize)],
            walPages: [0: page, 999_999: page]
        )

        #expect(merged.droppedOutOfRange == 1)
    }
}
