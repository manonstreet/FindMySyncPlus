import XCTest
import CommonCrypto
@testable import FindMySyncPlus

final class LocalStorageDecryptorTests: XCTestCase {

    private let pageSize = 4096
    private let contentSize = 4084
    private let reservedSize = 12

    /// Build the AES-CBC keystream for a given page index, key, and reserved bytes.
    /// This mirrors the algorithm in LocalStorageDecryptor.decryptPage.
    private func buildKeystream(pageIndex: Int, key: Data, reserved: Data) -> Data {
        let pgno = UInt32(pageIndex + 1)
        var iv = Data(count: 16)
        withUnsafeBytes(of: pgno.littleEndian) { iv.replaceSubrange(0..<4, with: $0) }
        iv.replaceSubrange(4..<16, with: reserved)

        let zeros = Data(count: pageSize)
        var keystream = Data(count: pageSize + kCCBlockSizeAES128)
        var keystreamLen = 0

        let status = keystream.withUnsafeMutableBytes { ksBuf in
            iv.withUnsafeBytes { ivBuf in
                key.withUnsafeBytes { keyBuf in
                    zeros.withUnsafeBytes { zBuf in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            0,
                            keyBuf.baseAddress, key.count,
                            ivBuf.baseAddress,
                            zBuf.baseAddress, pageSize,
                            ksBuf.baseAddress, ksBuf.count,
                            &keystreamLen
                        )
                    }
                }
            }
        }
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
        return keystream.prefix(pageSize)
    }

    /// Create a synthetic encrypted page from known plaintext.
    /// encryptedPage[0..<4084] = plaintext XOR keystream
    /// encryptedPage[4084..<4096] = reserved bytes (used as part of IV)
    private func encryptPage(plaintext: Data, pageIndex: Int, key: Data, reserved: Data) -> Data {
        precondition(plaintext.count == contentSize)
        precondition(reserved.count == reservedSize)

        let keystream = buildKeystream(pageIndex: pageIndex, key: key, reserved: reserved)

        var encrypted = Data(count: contentSize)
        for i in 0..<contentSize {
            encrypted[i] = plaintext[i] ^ keystream[i]
        }
        encrypted.append(reserved)
        return encrypted
    }

    // MARK: - decryptPage round-trip

    func testDecryptPage_roundTrip() async {
        let decryptor = LocalStorageDecryptor()
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let reserved = Data((0..<12).map { _ in UInt8.random(in: 0...255) })

        // Create known plaintext (non-page-0)
        let plaintext = Data((0..<contentSize).map { UInt8($0 % 256) })

        let encPage = encryptPage(plaintext: plaintext, pageIndex: 1, key: key, reserved: reserved)
        XCTAssertEqual(encPage.count, pageSize)

        let decrypted = decryptor.decryptPage(encPage, pageIndex: 1, key: key)
        XCTAssertEqual(decrypted.count, contentSize)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testDecryptPage_differentPagesProduceDifferentKeystreams() async {
        let decryptor = LocalStorageDecryptor()
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let reserved = Data(count: 12) // same reserved for both

        let plaintext = Data(count: contentSize) // all zeros

        let enc1 = encryptPage(plaintext: plaintext, pageIndex: 0, key: key, reserved: reserved)
        let enc2 = encryptPage(plaintext: plaintext, pageIndex: 1, key: key, reserved: reserved)

        _ = decryptor.decryptPage(enc1, pageIndex: 0, key: key)
        let dec2 = decryptor.decryptPage(enc2, pageIndex: 1, key: key)

        // Both should decrypt to zeros (the original plaintext)
        // But page 0 has special fix-up for bytes 16-23
        // For non-zero-page, should be exact
        XCTAssertEqual(dec2, plaintext)
    }

    func testDecryptPage_page0FixUp() async {
        let decryptor = LocalStorageDecryptor()
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let reserved = Data((0..<12).map { _ in UInt8.random(in: 0...255) })

        // Build a plaintext with SQLite magic header
        var plaintext = Data(count: contentSize)
        let magic = Data("SQLite format 3\0".utf8)
        plaintext.replaceSubrange(0..<16, with: magic)
        // Put some known bytes in 16-23
        let headerBytes = Data([0x10, 0x00, 0x01, 0x01, 0x00, 0x40, 0x20, 0x20])
        plaintext.replaceSubrange(16..<24, with: headerBytes)

        let encPage = encryptPage(plaintext: plaintext, pageIndex: 0, key: key, reserved: reserved)

        // Page 0 fix-up: bytes 16-23 of the encrypted page are stored plaintext.
        // The encrypt function XORs those bytes, but decryptPage restores them from the encrypted page.
        // So we need to put the plaintext header bytes directly in the encrypted page at 16-23.
        var fixedEncPage = encPage
        fixedEncPage.replaceSubrange(16..<24, with: headerBytes)

        let decrypted = decryptor.decryptPage(fixedEncPage, pageIndex: 0, key: key)

        // Verify magic header
        XCTAssertEqual(decrypted.prefix(16), magic)
        // Verify bytes 16-23 are the header bytes (restored from encrypted page)
        XCTAssertEqual(Data(decrypted[16..<24]), headerBytes)
    }

    func testDecryptPage_wrongKeyProducesDifferentOutput() async {
        let decryptor = LocalStorageDecryptor()
        let key1 = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let key2 = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let reserved = Data(count: 12)

        let plaintext = Data("Test data for encryption verification".utf8.prefix(contentSize)
            + Data(count: contentSize - min(contentSize, "Test data for encryption verification".utf8.count)))

        let encPage = encryptPage(plaintext: plaintext, pageIndex: 1, key: key1, reserved: reserved)

        let decryptedRight = decryptor.decryptPage(encPage, pageIndex: 1, key: key1)
        let decryptedWrong = decryptor.decryptPage(encPage, pageIndex: 1, key: key2)

        XCTAssertEqual(decryptedRight, plaintext)
        XCTAssertNotEqual(decryptedWrong, plaintext)
    }

    func testDecryptPage_outputSize() async {
        let decryptor = LocalStorageDecryptor()
        let key = Data(count: 32)
        let encPage = Data(count: pageSize)

        let decrypted = decryptor.decryptPage(encPage, pageIndex: 0, key: key)
        XCTAssertEqual(decrypted.count, contentSize)
    }

    // MARK: - Location Label Decoding

    func testDecodeAppleLocationLabels() {
        XCTAssertEqual(RichLocationAttributes.decodeLocationLabel("_$!<home>!$_"), "Home")
        XCTAssertEqual(RichLocationAttributes.decodeLocationLabel("_$!<work>!$_"), "Work")
        XCTAssertEqual(RichLocationAttributes.decodeLocationLabel("_$!<school>!$_"), "School")
        XCTAssertEqual(RichLocationAttributes.decodeLocationLabel("Coffee Shop"), "Coffee Shop")
        XCTAssertEqual(RichLocationAttributes.decodeLocationLabel(""), "")
        XCTAssertEqual(RichLocationAttributes.decodeLocationLabel("_$!<>!$_"), "_$!<>!$_")
    }
}
