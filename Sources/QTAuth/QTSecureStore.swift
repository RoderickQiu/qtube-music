import Foundation
import QTCore
import Security

/// Where the session lives: a private file in release builds, the shared dev Keychain item in DEBUG, memory in tests.
public protocol QTSecureStore: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
    func delete() throws
}

/// A session saved by an older version, moved once into the file store.
public protocol QTLegacySessionSource: Sendable {
    /// Must not prompt.
    func exists() -> Bool
    func read() throws -> Data?
    func delete() throws
}

/// The app's session store (release builds): a private file, `~/Library/Application Support/<bundle id>/Private/Session.json`
/// (`QTPrivateFile`: folder 0700, file 0600, not backed up). Not the Keychain: an ad-hoc signed app's Keychain access
/// is tied to each build's cdhash, so every update asked for the login password.
///
/// A session saved in the Keychain by 0.3.0 or earlier moves here on the first read: macOS asks one last time, then the
/// item is deleted. Denied, the app is signed out. Either way it's tried once (`migratedMarker`), and signing in or out
/// ends it too, so a sign-out can never bring the old session back. No Keychain item, no prompt.
public struct QTFileSecureStore: QTSecureStore {
    public let file: QTPrivateFile
    public let migratedMarker: QTPrivateFile
    public let legacy: (any QTLegacySessionSource)?

    public init(file: QTPrivateFile, migratedMarker: QTPrivateFile, legacy: (any QTLegacySessionSource)? = nil) {
        self.file = file
        self.migratedMarker = migratedMarker
        self.legacy = legacy
    }

    public static func applicationSupport(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.roderickqiu.qtube") -> QTFileSecureStore {
        QTFileSecureStore(file: .applicationSupport("Session.json", bundleIdentifier: bundleIdentifier),
                          migratedMarker: .applicationSupport("Session.migrated", bundleIdentifier: bundleIdentifier),
                          legacy: QTKeychainStore(account: QTKeychainStore.releaseAccount(bundleIdentifier: bundleIdentifier)))
    }

    public func read() throws -> Data? {
        let saved: Data?
        do { saved = try file.read() } catch { throw QTAuthError.storage }
        if let saved { return saved }
        return migrateLegacy()
    }

    public func write(_ data: Data) throws {
        do { try file.write(data) } catch { throw QTAuthError.storage }
        markMigrated()
    }

    public func delete() throws {
        do { try file.delete() } catch { throw QTAuthError.storage }
        markMigrated()
    }

    private func migrateLegacy() -> Data? {
        guard let legacy, (try? migratedMarker.read()) == nil else { return nil }
        guard legacy.exists() else {
            markMigrated()
            return nil
        }
        // The one prompt. Marked first, so a crash or a quit at the prompt doesn't ask at every launch.
        markMigrated()
        guard let data = try? legacy.read() else { return nil }
        // Only drop the old item once the file holds it; otherwise this launch still has the session in memory.
        if (try? file.write(data)) != nil { try? legacy.delete() }
        return data
    }

    private func markMigrated() {
        try? migratedMarker.write(Data())
    }
}

/// Keychain generic-password item (`kSecClassGenericPassword`, service `com.roderickqiu.qtube`): where 0.3.0 and
/// earlier kept the session. Now only the source of the one move into `QTFileSecureStore`.
public struct QTKeychainStore: QTSecureStore, QTLegacySessionSource {
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

    /// Attributes only, so another build's lookup doesn't prompt (checked 2026-11-01).
    public func exists() -> Bool {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
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
