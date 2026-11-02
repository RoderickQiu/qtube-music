import Foundation
import Observation
import QTCore
import Security

// QTIntegrations — opt-in connections to other services (spec §10). Everything is OFF by default and nothing is
// sent anywhere until the user turns a service on in Settings › Integrations:
//
// - Last.fm scrobbling (`QTLastFM*`, `QTScrobbler`): the app has no registered API account yet, so the user pastes
//   their own API key + shared secret (https://www.last.fm/api/account/create) and connects through Last.fm's web
//   authorization (auth.getToken → browser → auth.getSession). Now-playing updates, scrobbles per Last.fm's rules
//   (> 30 s; half the track or 4 minutes), an offline queue that survives relaunch.
// - ListenBrainz (`QTListenBrainz*`): the user pastes their user token (https://listenbrainz.org/settings/), Connect
//   checks it (validate-token). The same listens as Last.fm, with their own queue. A custom server URL covers
//   ListenBrainz-compatible servers (Maloja, self-hosted ListenBrainz).
// - Discord Rich Presence (`QTDiscord*`): the local IPC socket of the Discord desktop app (no network from us);
//   the user enters the client ID of a Discord application they created.
// - Track-change notifications (`notifiesTrackChanges`), shown by the app target via UNUserNotificationCenter.
//
// Secrets (Last.fm shared secret and session key, the ListenBrainz token) live in the Keychain, never in defaults, files or logs.

/// Non-secret integration preferences (UserDefaults `qt.integrations.v1`).
public struct QTIntegrationsSettings: Codable, Sendable, Hashable {
    public var lastFM = QTLastFMPrefs()
    public var listenBrainz = QTListenBrainzPrefs()
    public var discord = QTDiscordPrefs()
    /// Post a notification when the song changes while QTube Music isn't frontmost. Off by default; turning it on
    /// asks macOS for permission.
    public var notifiesTrackChanges = false

    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = QTIntegrationsSettings()
        lastFM = (try? c.decodeIfPresent(QTLastFMPrefs.self, forKey: .lastFM)) ?? d.lastFM
        listenBrainz = (try? c.decodeIfPresent(QTListenBrainzPrefs.self, forKey: .listenBrainz)) ?? d.listenBrainz
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

public struct QTListenBrainzPrefs: Codable, Sendable, Hashable {
    /// Submitting switch (needs a connected account too).
    public var isEnabled = false
    /// Set once connected: the ListenBrainz user name (display only). The token is in the Keychain.
    public var username: String?
    public var sendsNowPlaying = true
    /// API root of a ListenBrainz-compatible server; empty = listenbrainz.org. Fixed while connected (the token
    /// belongs to that server).
    public var serverURL = ""

    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = QTListenBrainzPrefs()
        isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? d.isEnabled
        username = try? c.decodeIfPresent(String.self, forKey: .username)
        sendsNowPlaying = (try? c.decodeIfPresent(Bool.self, forKey: .sendsNowPlaying)) ?? d.sendsNowPlaying
        serverURL = (try? c.decodeIfPresent(String.self, forKey: .serverURL)) ?? d.serverURL
    }

    public var isConnected: Bool { username != nil }
    /// The API root to use (nil = the field isn't a usable URL).
    public var server: URL? { QTListenBrainzRequest.server(from: serverURL) }
    /// The custom server's host, nil for listenbrainz.org.
    public var customServerHost: String? {
        guard let server, server != QTListenBrainzRequest.defaultServer else { return nil }
        return server.host
    }
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
        self.secrets = secrets ?? QTFileSecretStore.applicationSupport()
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

    /// The API account and session key for scrobbling, read from the Keychain **off the main thread**: a Keychain
    /// read can wait on a system prompt (an ad-hoc build reading an item a previous build saved), and the
    /// integrations configure themselves at launch. nil when Last.fm isn't set up and connected.
    public func loadLastFMSession() async -> (credentials: QTLastFMCredentials, sessionKey: String)? {
        let prefs = settings.lastFM
        let key = prefs.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, prefs.hasSecret, prefs.isConnected else { return nil }
        let secrets = secrets
        return await Task.detached(priority: .utility) { () -> (credentials: QTLastFMCredentials, sessionKey: String)? in
            guard let secret = secrets.get(.lastFMSecret), let session = secrets.get(.lastFMSessionKey) else { return nil }
            return (QTLastFMCredentials(apiKey: key, apiSecret: secret), session)
        }.value
    }

    // MARK: ListenBrainz

    /// Saves the token (Keychain) of the account Connect validated, and turns submitting on.
    public func connectListenBrainz(token: String, username: String) {
        secrets.set(token.trimmingCharacters(in: .whitespacesAndNewlines), for: .listenBrainzToken)
        update {
            $0.listenBrainz.username = username
            $0.listenBrainz.isEnabled = true
        }
    }

    public func disconnectListenBrainz() {
        secrets.remove(.listenBrainzToken)
        update {
            $0.listenBrainz.username = nil
            $0.listenBrainz.isEnabled = false
        }
    }

    /// The token and server for submitting, the token read from the Keychain **off the main thread** (see
    /// `loadLastFMSession`). nil when ListenBrainz isn't connected.
    public func loadListenBrainzSession() async -> (token: String, server: URL)? {
        let prefs = settings.listenBrainz
        guard prefs.isConnected, let server = prefs.server else { return nil }
        let secrets = secrets
        return await Task.detached(priority: .utility) { () -> (token: String, server: URL)? in
            secrets.get(.listenBrainzToken).map { ($0, server) }
        }.value
    }
}

// MARK: - Secrets

public enum QTIntegrationSecret: String, Sendable, CaseIterable {
    case lastFMSecret = "lastfm.secret"
    case lastFMSessionKey = "lastfm.session"
    case listenBrainzToken = "listenbrainz.token"
}

public protocol QTIntegrationSecretStore: Sendable {
    func get(_ secret: QTIntegrationSecret) -> String?
    func set(_ value: String, for secret: QTIntegrationSecret)
    func remove(_ secret: QTIntegrationSecret)
}

/// Integration keys saved by an older version, moved once into the file store.
public protocol QTLegacyIntegrationSecrets: QTIntegrationSecretStore {
    /// Must not prompt.
    func exists(_ secret: QTIntegrationSecret) -> Bool
}

/// The integration keys (Last.fm secret and session key, ListenBrainz token) in one private file,
/// `~/Library/Application Support/<bundle id>/Private/Integrations.json` (`QTPrivateFile`: 0600, not backed up), next
/// to the YouTube Music session — not the Keychain, which asked for the login password after every update of an
/// ad-hoc signed build. Keys saved in the Keychain by 0.3.0 or earlier move here on first use: macOS asks one last time
/// per key that exists, then the items are deleted. Tried once (`migratedMarker`); no items, no prompt.
public final class QTFileSecretStore: QTIntegrationSecretStore, @unchecked Sendable {
    private let file: QTPrivateFile
    private let migratedMarker: QTPrivateFile
    private let legacy: (any QTLegacyIntegrationSecrets)?
    private let lock = NSLock()

    public init(file: QTPrivateFile, migratedMarker: QTPrivateFile, legacy: (any QTLegacyIntegrationSecrets)? = nil) {
        self.file = file
        self.migratedMarker = migratedMarker
        self.legacy = legacy
    }

    public static func applicationSupport() -> QTFileSecretStore {
        // DEBUG builds and tests never touch the installed app's Keychain items.
        #if DEBUG
        let legacy: (any QTLegacyIntegrationSecrets)? = nil
        #else
        let legacy: (any QTLegacyIntegrationSecrets)? = QTKeychainSecretStore()
        #endif
        return QTFileSecretStore(file: .applicationSupport("Integrations.json"),
                                 migratedMarker: .applicationSupport("Integrations.migrated"),
                                 legacy: legacy)
    }

    public func get(_ secret: QTIntegrationSecret) -> String? {
        lock.withLock { load()[secret.rawValue] }
    }

    public func set(_ value: String, for secret: QTIntegrationSecret) {
        lock.withLock {
            var all = load()
            all[secret.rawValue] = value
            save(all)
        }
    }

    public func remove(_ secret: QTIntegrationSecret) {
        lock.withLock {
            var all = load()
            guard all.removeValue(forKey: secret.rawValue) != nil else { return }
            save(all)
        }
    }

    private func load() -> [String: String] {
        var all: [String: String] = [:]
        if let data = try? file.read() {
            all = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }
        migrateLegacy(into: &all)
        return all
    }

    private func migrateLegacy(into all: inout [String: String]) {
        guard let legacy, (try? migratedMarker.read()) == nil else { return }
        // Marked first, so a quit at a prompt doesn't ask at every launch.
        try? migratedMarker.write(Data())
        var moved: [QTIntegrationSecret] = []
        for secret in QTIntegrationSecret.allCases where legacy.exists(secret) {
            guard let value = legacy.get(secret) else { continue }
            if all[secret.rawValue] == nil { all[secret.rawValue] = value }
            moved.append(secret)
        }
        guard !moved.isEmpty, let data = try? JSONEncoder().encode(all), (try? file.write(data)) != nil else { return }
        moved.forEach(legacy.remove)
    }

    private func save(_ all: [String: String]) {
        if all.isEmpty {
            try? file.delete()
        } else if let data = try? JSONEncoder().encode(all) {
            try? file.write(data)
        }
    }
}

/// Generic-password Keychain items, service `com.roderickqiu.qtube.integrations`, one account per secret: where 0.3.0
/// and earlier kept the keys. Now only the source of the one move into `QTFileSecretStore`.
public struct QTKeychainSecretStore: QTLegacyIntegrationSecrets {
    public let service: String

    public init(service: String = "com.roderickqiu.qtube.integrations") {
        self.service = service
    }

    private func query(_ secret: QTIntegrationSecret) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: secret.rawValue]
    }

    /// Attributes only, so another build's lookup doesn't prompt.
    public func exists(_ secret: QTIntegrationSecret) -> Bool {
        var q = query(secret)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
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
