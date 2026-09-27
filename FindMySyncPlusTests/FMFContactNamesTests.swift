import Foundation
import CryptoKit
import Testing
@testable import FindMySyncPlus

/// `CacheDecryptor.fmfContactNames`: only a key that fails to authenticate reads as incorrect.
struct FMFContactNamesTests {

    private let key = SymmetricKey(size: .bits256)

    private func cache(contacts: [String: Any], sealedWith sealKey: SymmetricKey) throws -> Data {
        let plaintext = try PropertyListSerialization.data(
            fromPropertyList: ["contacts": contacts], format: .binary, options: 0)
        let sealed = try ChaChaPoly.seal(plaintext, using: sealKey)
        var encrypted = Data()
        encrypted.append(contentsOf: sealed.nonce)
        encrypted.append(sealed.ciphertext)
        encrypted.append(sealed.tag)
        return try PropertyListSerialization.data(
            fromPropertyList: ["encryptedData": encrypted], format: .binary, options: 0)
    }

    @Test func theRightKeyReadsDisplayNamesFallingBackToShortNames() throws {
        let data = try cache(contacts: ["111": ["displayName": "Test Friend"],
                                        "222": ["shortName": "Pal"],
                                        "333": ["displayName": ""]],
                             sealedWith: key)
        #expect(CacheDecryptor.fmfContactNames(fromCache: data, key: key)
                == .names(["111": "Test Friend", "222": "Pal"]))
    }

    @Test func anotherKeyIsIncorrect() throws {
        let data = try cache(contacts: ["111": ["displayName": "Test Friend"]], sealedWith: key)
        #expect(CacheDecryptor.fmfContactNames(fromCache: data, key: SymmetricKey(size: .bits256))
                == .incorrectKey)
    }

    @Test func aCacheWithNoPayloadIsUnavailableNotIncorrect() throws {
        let noPayload = try PropertyListSerialization.data(
            fromPropertyList: ["other": 1], format: .binary, options: 0)
        guard case .unavailable = CacheDecryptor.fmfContactNames(fromCache: noPayload, key: key) else {
            Issue.record("expected .unavailable")
            return
        }
        guard case .unavailable = CacheDecryptor.fmfContactNames(fromCache: Data("junk".utf8), key: key) else {
            Issue.record("expected .unavailable")
            return
        }
    }
}
