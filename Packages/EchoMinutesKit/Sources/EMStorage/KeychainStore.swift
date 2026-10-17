import EMCore
import Foundation
import Security

/// API keys live only in the macOS Keychain (Technical Design §11.3, TD-8). EM-026.
/// One generic-password item per provider: service = `service`, account = provider raw value.
public struct KeychainStore: Sendable {
    public static let defaultService = "com.tanimkabir.echominutes.providers"
    public let service: String

    public init(service: String = KeychainStore.defaultService) { self.service = service }

    public enum KeychainError: Error, Equatable, Sendable { case unexpectedStatus(OSStatus), invalidData }

    public func set(_ key: String, for provider: ProviderID) throws {
        try set(key, account: provider.rawValue, label: provider.displayName)
    }

    public func get(_ provider: ProviderID) throws -> String? { try get(account: provider.rawValue) }

    public func delete(_ provider: ProviderID) throws { try delete(account: provider.rawValue) }

    public func hasKey(_ provider: ProviderID) -> Bool { ((try? get(provider)) ?? nil) != nil }

    // MARK: Any account (cloud transcription keys, EM-162)

    public func set(_ key: String, account: String, label: String) throws {
        let data = Data(key.utf8)
        let query = baseQuery(account)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            add[kSecAttrLabel as String] = "EchoMinutes – \(label) API key"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    public func get(account: String) throws -> String? {
        var q = baseQuery(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = item as? Data, let s = String(data: data, encoding: .utf8) else { throw KeychainError.invalidData }
        return s
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.unexpectedStatus(status) }
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
