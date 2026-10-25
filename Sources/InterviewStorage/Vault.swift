import Foundation
import CryptoKit
import Security
import InterviewCore

/// AES-GCM encryption for records at rest. The key lives in the login Keychain; the database never holds it.
public struct DataVault: Sendable {
    private let key: SymmetricKey
    public init(key: SymmetricKey) { self.key = key }

    public func seal(_ data: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key).combined else { throw AssistantError.internalFailure("seal") }
        return combined
    }

    public func open(_ data: Data) throws -> Data {
        try AES.GCM.open(try AES.GCM.SealedBox(combined: data), using: key)
    }

    public func seal<T: Encodable>(_ value: T) throws -> Data { try seal(try JSONCoding.encoder.encode(value)) }
    public func open<T: Decodable>(_ type: T.Type, from data: Data) throws -> T { try JSONCoding.decoder.decode(T.self, from: try open(data)) }

    public static func ephemeral() -> DataVault { DataVault(key: SymmetricKey(size: .bits256)) }
}

public enum JSONCoding {
    public static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }()
    public static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

/// Generic-password Keychain items for the vault key and provider API keys (plan §6.2, F86).
public struct KeychainStore: Sendable {
    public let service: String
    public init(service: String) { self.service = service }

    public func set(_ value: Data, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let attributes: [String: Any] = [kSecValueData as String: value, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AssistantError.internalFailure("keychain write \(status)") }
    }

    public func get(account: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw AssistantError.internalFailure("keychain read \(status)") }
        return item as? Data
    }

    public func delete(account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AssistantError.internalFailure("keychain delete \(status)") }
    }

    public func setString(_ value: String, account: String) throws { try set(Data(value.utf8), account: account) }
    public func getString(account: String) throws -> String? { try get(account: account).flatMap { String(data: $0, encoding: .utf8) } }

    /// Loads or creates the vault key.
    public func vaultKey() throws -> SymmetricKey {
        if let data = try get(account: "vault-key") { return SymmetricKey(data: data) }
        let key = SymmetricKey(size: .bits256)
        try set(key.withUnsafeBytes { Data($0) }, account: "vault-key")
        return key
    }
}
