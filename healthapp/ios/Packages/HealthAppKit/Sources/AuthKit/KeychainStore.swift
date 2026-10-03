#if canImport(Security)
import Foundation
import Security

/// Minimal generic-password Keychain wrapper. Items use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
/// (available to background refresh after first unlock, never migrated to other devices/backups).
public struct KeychainStore: Sendable {
    public enum KeychainError: Error, Equatable { case unexpectedStatus(OSStatus) }

    public let service: String

    public init(service: String = "com.healthapp.ios.auth") { self.service = service }

    public func set(_ data: Data, for key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attributes) { $1 }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func data(for key: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        return item as? Data
    }

    public func remove(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    public func setCodable<T: Encodable>(_ value: T, for key: String) throws {
        try set(try JSONEncoder().encode(value), for: key)
    }

    public func codable<T: Decodable>(_ type: T.Type, for key: String) throws -> T? {
        guard let data = try data(for: key) else { return nil }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
#endif
