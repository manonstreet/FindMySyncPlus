import Foundation
import Security

enum KeychainKey: String {
    case endpointAuth = "endpointAuth"         // String
    case fmipSymmetricKey = "fmipSymmetricKey" // raw bytes
    case fmfKey = "fmfKey"                    // raw bytes (FMF symmetric key)
    case localStorageKey = "localStorageKey"   // raw 32 bytes (AES-256)
    case mqttPassword = "mqttPassword"         // String (MQTT broker password)
}

enum Keychain {
    private static var service: String { Bundle.main.bundleIdentifier ?? "com.manonstreet.findmysyncplus" }

    @discardableResult
    static func set(_ data: Data, for key: KeychainKey) -> Bool {
        save(data, for: key) == nil
    }

    /// Stores `data`, returning why the Keychain refused it, or `nil` on success.
    static func save(_ data: Data, for key: KeychainKey) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status: OSStatus
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        } else {
            var add = query
            attrs.forEach { add[$0.key] = $0.value }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status == errSecSuccess ? nil : describe(status)
    }

    @discardableResult
    static func setString(_ string: String, for key: KeychainKey) -> Bool {
        set(Data(string.utf8), for: key)
    }

    static func saveString(_ string: String, for key: KeychainKey) -> String? {
        save(Data(string.utf8), for: key)
    }

    static func getData(for key: KeychainKey) -> Data? {
        read(key).data
    }

    /// The stored bytes, and why the read failed when the item exists but could not be
    /// returned — a locked keychain or a refused access prompt. Absent is not a failure.
    static func read(_ key: KeychainKey) -> (data: Data?, failure: String?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data { return (data, nil) }
        if status == errSecItemNotFound { return (nil, nil) }
        return (nil, describe(status))
    }

    static func describe(_ status: OSStatus) -> String {
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return "\(text) (status \(status))"
    }

    static func getString(for key: KeychainKey) -> String? {
        guard let data = getData(for: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(_ key: KeychainKey) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}
