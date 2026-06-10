import Foundation
#if canImport(Security)
import Security
#endif

/// Where the API key and stream keys live. Abstracted so tests (and non-Apple
/// hosts) can use `InMemoryTokenStore`.
public protocol TokenStore: Sendable {
    func read(account: String) throws -> String?
    func write(_ value: String, account: String) throws
    func delete(account: String) throws
}

/// Well-known Keychain account names.
public enum TokenAccount {
    public static let apiKey = "api-key"
}

public enum TokenStoreError: Error {
    case osStatus(Int32)
    case unsupportedPlatform
}

public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func read(account: String) throws -> String? {
        lock.withLock { storage[account] }
    }

    public func write(_ value: String, account: String) throws {
        lock.withLock { storage[account] = value }
    }

    public func delete(account: String) throws {
        _ = lock.withLock { storage.removeValue(forKey: account) }
    }
}

/// Generic-password Keychain items under service `co.grio.cobbvision`.
public struct KeychainStore: TokenStore {
    public static let service = "co.grio.cobbvision"

    public init() {}

    public func read(account: String) throws -> String? {
        #if canImport(Security)
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw TokenStoreError.osStatus(status)
        }
        #else
        throw TokenStoreError.unsupportedPlatform
        #endif
    }

    public func write(_ value: String, account: String) throws {
        #if canImport(Security)
        let data = Data(value.utf8)
        var query = baseQuery(account: account)
        let update: [String: Any] = [kSecValueData as String: data]

        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw TokenStoreError.osStatus(status) }
        #else
        throw TokenStoreError.unsupportedPlatform
        #endif
    }

    public func delete(account: String) throws {
        #if canImport(Security)
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TokenStoreError.osStatus(status)
        }
        #else
        throw TokenStoreError.unsupportedPlatform
        #endif
    }

    #if canImport(Security)
    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
    }
    #endif
}
