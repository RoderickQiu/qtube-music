import Foundation
import Observation
import Security

// QTIntegrations — opt-in connections to other services (spec §10). Everything is OFF by default and nothing is
// sent anywhere until the user turns a service on in Settings › Integrations:
//
// - Last.fm scrobbling (`QTLastFM*`, `QTScrobbler`): the app has no registered API account yet, so the user pastes
//   their own API key + shared secret (https://www.last.fm/api/account/create) and connects through Last.fm's web
//   authorization (auth.getToken → browser → auth.getSession). Now-playing updates, scrobbles per Last.fm's rules
//   (> 30 s; half the track or 4 minutes), an offline queue that survives relaunch.
// - Discord Rich Presence (`QTDiscord*`): the local IPC socket of the Discord desktop app (no network from us);
//   the user enters the client ID of a Discord application they created.
// - Track-change notifications (`notifiesTrackChanges`), shown by the app target via UNUserNotificationCenter.
//
// Secrets (Last.fm shared secret and session key) live in the Keychain, never in defaults, files or logs.

/// Non-secret integration preferences (UserDefaults `qt.integrations.v1`).
public struct QTIntegrationsSettings: Codable, Sendable, Hashable {
    public var lastFM = QTLastFMPrefs()
    public var discord = QTDiscordPrefs()
    /// Post a notification when the song changes while QTube Music isn't frontmost. Off by default; turning it on
    /// asks macOS for permission.
    public var notifiesTrackChanges = false

    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = QTIntegrationsSettings()
        lastFM = (try? c.decodeIfPresent(QTLastFMPrefs.self, forKey: .lastFM)) ?? d.lastFM
        discord = (try? c.decodeIfPresent(QTDiscordPrefs.self, forKey: .discord)) ?? d.discord
        notifiesTrackChanges = (try? c.decodeIfPresent(Bool.self, forKey: .notifiesTrackChanges)) ?? d.notifiesTrackChanges
    }
}

public struct QTLastFMPrefs: Codable, Sendable, Hashable {
    /// Scrobbling switch (needs a connected account too).
    public var isEnabled = false
    /// The user's Last.fm API key (public half of their API account).
    public var apiKey = ""
    /// Set once connected: the Last.fm user name (display only). The session key is in the Keychain.
    public var username: String?
    /// True when a shared secret has been saved to the Keychain (the field shows "Saved" instead of reading it).
    public var hasSecret = false
    public var sendsNowPlaying = true

    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = QTLastFMPrefs()
        isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? d.isEnabled
        apiKey = (try? c.decodeIfPresent(String.self, forKey: .apiKey)) ?? d.apiKey
        username = try? c.decodeIfPresent(String.self, forKey: .username)
        hasSecret = (try? c.decodeIfPresent(Bool.self, forKey: .hasSecret)) ?? d.hasSecret
        sendsNowPlaying = (try? c.decodeIfPresent(Bool.self, forKey: .sendsNowPlaying)) ?? d.sendsNowPlaying
    }

    public var isConnected: Bool { username != nil }
}

public struct QTDiscordPrefs: Codable, Sendable, Hashable {
    public var isEnabled = false
    /// "Application ID" of the user's Discord application (developer portal); digits only.
    public var clientID = ""
    /// Show the album art (by its public URL) as the large image.
    public var showsArtwork = true

    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = QTDiscordPrefs()
        isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? d.isEnabled
        clientID = (try? c.decodeIfPresent(String.self, forKey: .clientID)) ?? d.clientID
        showsArtwork = (try? c.decodeIfPresent(Bool.self, forKey: .showsArtwork)) ?? d.showsArtwork
    }

    /// A Discord snowflake: 17–20 digits.
    public var hasValidClientID: Bool {
        (17...20).contains(clientID.count) && clientID.allSatisfy(\.isASCII) && clientID.allSatisfy(\.isNumber)
    }
}

/// Owns `QTIntegrationsSettings` (persisted on every change, like `QTSettingsStore`).
@MainActor
@Observable
public final class QTIntegrationsStore {
    public private(set) var settings: QTIntegrationsSettings
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored public let secrets: any QTIntegrationSecretStore

    public static let defaultsKey = "qt.integrations.v1"

    public init(defaults: UserDefaults = .standard, secrets: (any QTIntegrationSecretStore)? = nil) {
        self.defaults = defaults
        self.secrets = secrets ?? QTKeychainSecretStore()
        settings = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(QTIntegrationsSettings.self, from: $0) } ?? QTIntegrationsSettings()
    }

    public func update(_ change: (inout QTIntegrationsSettings) -> Void) {
        change(&settings)
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    // MARK: Last.fm secrets

    /// Saves the shared secret (Keychain) and remembers that one is set.
    public func setLastFMSecret(_ secret: String) {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            secrets.remove(.lastFMSecret)
        } else {
            secrets.set(trimmed, for: .lastFMSecret)
        }
        update { $0.lastFM.hasSecret = !trimmed.isEmpty }
    }

    public func lastFMCredentials() -> QTLastFMCredentials? {
        let key = settings.lastFM.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, settings.lastFM.hasSecret, let secret = secrets.get(.lastFMSecret) else { return nil }
        return QTLastFMCredentials(apiKey: key, apiSecret: secret)
    }

    public func connectLastFM(session: QTLastFMSession) {
        secrets.set(session.key, for: .lastFMSessionKey)
        update {
            $0.lastFM.username = session.name
            $0.lastFM.isEnabled = true
        }
    }

    public func disconnectLastFM() {
        secrets.remove(.lastFMSessionKey)
        update {
            $0.lastFM.username = nil
            $0.lastFM.isEnabled = false
        }
    }

    public var lastFMSessionKey: String? {
        settings.lastFM.isConnected ? secrets.get(.lastFMSessionKey) : nil
    }
}

// MARK: - Secrets

public enum QTIntegrationSecret: String, Sendable, CaseIterable {
    case lastFMSecret = "lastfm.secret"
    case lastFMSessionKey = "lastfm.session"
}

public protocol QTIntegrationSecretStore: Sendable {
    func get(_ secret: QTIntegrationSecret) -> String?
    func set(_ value: String, for secret: QTIntegrationSecret)
    func remove(_ secret: QTIntegrationSecret)
}

/// Generic-password Keychain items, service `com.roderickqiu.qtube.integrations`, one account per secret.
public struct QTKeychainSecretStore: QTIntegrationSecretStore {
    public let service: String

    public init(service: String = "com.roderickqiu.qtube.integrations") {
        self.service = service
    }

    private func query(_ secret: QTIntegrationSecret) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: secret.rawValue]
    }

    public func get(_ secret: QTIntegrationSecret) -> String? {
        var q = query(secret)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func set(_ value: String, for secret: QTIntegrationSecret) {
        remove(secret)
        var q = query(secret)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }

    public func remove(_ secret: QTIntegrationSecret) {
        SecItemDelete(query(secret) as CFDictionary)
    }
}

/// In-memory secrets (tests, previews).
public final class QTMemorySecretStore: QTIntegrationSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [QTIntegrationSecret: String] = [:]
    public init(_ values: [QTIntegrationSecret: String] = [:]) { self.values = values }
    public func get(_ secret: QTIntegrationSecret) -> String? { lock.withLock { values[secret] } }
    public func set(_ value: String, for secret: QTIntegrationSecret) { lock.withLock { values[secret] = value } }
    public func remove(_ secret: QTIntegrationSecret) { _ = lock.withLock { values.removeValue(forKey: secret) } }
}
