import Foundation
import Security

/// Where the session lives. The app uses the Keychain; tests use memory.
public protocol QTSecureStore: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
    func delete() throws
}

/// Keychain generic-password item (`kSecClassGenericPassword`, service `com.roderickqiu.qtube`).
public struct QTKeychainStore: QTSecureStore {
    public static let defaultService = "com.roderickqiu.qtube"
    public static let defaultAccount = "youtube-music-session"

    public let service: String
    public let account: String

    public init(service: String = QTKeychainStore.defaultService, account: String = QTKeychainStore.defaultAccount) {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func read() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw QTAuthError.keychain(status: status)
        }
    }

    public func write(_ data: Data) throws {
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add.merge(attributes) { $1 }
            add[kSecAttrLabel as String] = "QTube Music — YouTube Music session"
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw QTAuthError.keychain(status: addStatus) }
        } else if status != errSecSuccess {
            throw QTAuthError.keychain(status: status)
        }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw QTAuthError.keychain(status: status) }
    }
}

/// In-memory store (tests, previews).
public final class QTMemorySecureStore: QTSecureStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    public init(data: Data? = nil) { self.data = data }

    public func read() throws -> Data? { lock.withLock { data } }
    public func write(_ data: Data) throws { lock.withLock { self.data = data } }
    public func delete() throws { lock.withLock { data = nil } }
}
