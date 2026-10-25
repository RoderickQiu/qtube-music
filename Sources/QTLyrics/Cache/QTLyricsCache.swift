import Foundation
import OSLog
import QTCore
import SQLite3

/// What the resolver stores per video: the chosen document, the other versions for the
/// "Lyrics Source" menu, and the source configuration it was resolved under.
public struct QTLyricsCacheEntry: Sendable, Hashable, Codable {
    public var videoId: String
    /// nil = nothing found (negative cache; shorter lifetime).
    public var document: QTLyricsDocument?
    public var versions: [QTResolvedLyricsVersion]
    public var chosenID: String?
    public var attribution: String?
    /// Fingerprint of the enabled sources; a different set triggers a fresh lookup.
    public var sourcesKey: String
    public var updated: Date
    /// True when some enabled sources were unreachable during the lookup (shorter lifetime; nil in older entries).
    public var isPartial: Bool?

    public init(videoId: String, document: QTLyricsDocument?, versions: [QTResolvedLyricsVersion], chosenID: String?,
                attribution: String?, sourcesKey: String, updated: Date = Date()) {
        self.videoId = videoId
        self.document = document
        self.versions = versions
        self.chosenID = chosenID
        self.attribution = attribution
        self.sourcesKey = sourcesKey
        self.updated = updated
    }
}

/// SQLite store (system `sqlite3`, no dependencies) for lyrics keyed by videoId, offsets per track and version,
/// pinned versions, reported ("wrong") versions, fingerprints of the chosen texts, learned aliases, machine
/// translations and small blobs (the AMLL index). Offsets, pins, reports and aliases are user data, so the default
/// file lives in Application Support, not Caches.
public actor QTLyricsCache {
    private let connection: QTSQLiteConnection
    private var db: OpaquePointer? { connection.handle }
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// `nil` URL = in-memory database (tests, previews).
    public init(url: URL?) throws {
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        var handle: OpaquePointer?
        let path = url?.path ?? ":memory:"
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw QTLyricsCacheError.sqlite(message)
        }
        connection = QTSQLiteConnection(handle)
        // Another copy of the app (`open -n`) may hold the file for a moment: wait instead of failing at once.
        sqlite3_busy_timeout(handle, Self.busyTimeoutMilliseconds)
        let schema = """
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;
        CREATE TABLE IF NOT EXISTS lyrics (video_id TEXT PRIMARY KEY, entry BLOB NOT NULL, updated REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS pins (video_id TEXT PRIMARY KEY, version_id TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS aliases (a TEXT NOT NULL, b TEXT NOT NULL, origin TEXT, PRIMARY KEY (a, b));
        CREATE TABLE IF NOT EXISTS translations (video_id TEXT NOT NULL, language TEXT NOT NULL, engine TEXT NOT NULL,
            lines BLOB NOT NULL, updated REAL NOT NULL, PRIMARY KEY (video_id, language, engine));
        CREATE TABLE IF NOT EXISTS blobs (name TEXT PRIMARY KEY, data BLOB NOT NULL, updated REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS version_offsets (video_id TEXT NOT NULL, version_id TEXT NOT NULL, offset REAL NOT NULL,
            PRIMARY KEY (video_id, version_id));
        CREATE TABLE IF NOT EXISTS rejections (video_id TEXT NOT NULL, version_id TEXT NOT NULL, updated REAL NOT NULL,
            PRIMARY KEY (video_id, version_id));
        CREATE TABLE IF NOT EXISTS fingerprints (hash TEXT NOT NULL, video_id TEXT NOT NULL, title TEXT NOT NULL,
            artist TEXT NOT NULL DEFAULT '', PRIMARY KEY (hash, video_id));
        """
        if sqlite3_exec(handle, schema, nil, nil, nil) != SQLITE_OK {
            throw QTLyricsCacheError.sqlite(String(cString: sqlite3_errmsg(handle)))
        }
        // A migration that can't finish is rolled back and tried again at the next launch; the cache opens either
        // way, so pins, reports and offsets keep being saved meanwhile.
        do {
            try Self.migrate(handle)
        } catch {
            Logger(subsystem: "com.roderickqiu.qtube", category: "lyrics").error("lyrics cache migration failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// `PRAGMA user_version` of the current schema.
    static let schemaVersion: Int32 = 2
    static let busyTimeoutMilliseconds: Int32 = 3_000

    /// Every step runs in one transaction; any failed statement rolls all of it back.
    /// - 0 → 1: offsets were per track (`offsets`); they are now per track and version, so a newly picked version
    ///   starts at zero. An existing offset was tuned for what was showing: the pinned version, else the cached
    ///   automatic pick; with neither known it is kept under `""` and goes to the first version shown
    ///   (`offset(for:version:)`).
    /// - 1 → 2: fingerprints gain the artist and are started afresh (earlier builds also recorded versions that were
    ///   never shown, which could mark the right lyrics as another song's).
    static func migrate(_ db: OpaquePointer) throws {
        var stmt: OpaquePointer?
        var version: Int32 = 0
        if sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW {
            version = sqlite3_column_int(stmt, 0)
        }
        sqlite3_finalize(stmt)
        guard version < schemaVersion else { return }
        try exec(db, "BEGIN IMMEDIATE")
        do {
            if version < 1 { try migrateOffsets(db) }
            if version < 2 {
                try exec(db, """
                    DROP TABLE IF EXISTS fingerprints;
                    CREATE TABLE fingerprints (hash TEXT NOT NULL, video_id TEXT NOT NULL, title TEXT NOT NULL,
                        artist TEXT NOT NULL DEFAULT '', PRIMARY KEY (hash, video_id));
                    """)
            }
            try exec(db, "PRAGMA user_version = \(schemaVersion)")
            try exec(db, "COMMIT")
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private static func migrateOffsets(_ db: OpaquePointer) throws {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        // A fresh file has no `offsets` table: nothing to carry over.
        guard sqlite3_prepare_v2(db, """
            SELECT o.video_id, o.offset, p.version_id, l.entry FROM offsets o
            LEFT JOIN pins p ON p.video_id = o.video_id LEFT JOIN lyrics l ON l.video_id = o.video_id
            """, -1, &stmt, nil) == SQLITE_OK, let select = stmt else { return }
        let decoder = JSONDecoder()
        var legacy: [(videoId: String, offset: Double, version: String)] = []
        var rc = sqlite3_step(select)
        while rc == SQLITE_ROW {
            let pin = sqlite3_column_text(select, 2).map { String(cString: $0) }
            let entry = blob(select, 3)
            let chosen = entry.isEmpty ? nil : (try? decoder.decode(QTLyricsCacheEntry.self, from: entry))?.chosenID
            legacy.append((text(select, 0), sqlite3_column_double(select, 1),
                           pin.flatMap { $0 == QTLyricsCache.noLyricsPin ? nil : $0 } ?? chosen ?? ""))
            rc = sqlite3_step(select)
        }
        guard rc == SQLITE_DONE else { throw QTLyricsCacheError.sqlite(String(cString: sqlite3_errmsg(db))) }
        sqlite3_finalize(select)
        stmt = nil
        for row in legacy {
            guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO version_offsets (video_id, version_id, offset) VALUES (?, ?, ?)",
                                     -1, &stmt, nil) == SQLITE_OK else { throw QTLyricsCacheError.sqlite(String(cString: sqlite3_errmsg(db))) }
            sqlite3_bind_text(stmt, 1, row.videoId, -1, transient)
            sqlite3_bind_text(stmt, 2, row.version, -1, transient)
            sqlite3_bind_double(stmt, 3, row.offset)
            let done = sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            stmt = nil
            guard done == SQLITE_DONE else { throw QTLyricsCacheError.sqlite(String(cString: sqlite3_errmsg(db))) }
        }
        try exec(db, "DROP TABLE offsets")
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw QTLyricsCacheError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// `~/Library/Application Support/<bundle id>/Lyrics.sqlite`.
    public static func defaultURL(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent(bundleIdentifier ?? "com.roderickqiu.qtube", isDirectory: true)
            .appendingPathComponent("Lyrics.sqlite")
    }

    // MARK: Lyrics

    public func entry(for videoId: String) -> QTLyricsCacheEntry? {
        guard let data = queryBlob("SELECT entry FROM lyrics WHERE video_id = ?", [videoId]) else { return nil }
        return try? decoder.decode(QTLyricsCacheEntry.self, from: data)
    }

    public func store(_ entry: QTLyricsCacheEntry) {
        guard let data = try? encoder.encode(entry) else { return }
        run("INSERT OR REPLACE INTO lyrics (video_id, entry, updated) VALUES (?, ?, ?)",
            [.text(entry.videoId), .blob(data), .real(entry.updated.timeIntervalSince1970)])
    }

    public func removeEntry(for videoId: String) {
        run("DELETE FROM lyrics WHERE video_id = ?", [.text(videoId)])
    }

    // MARK: Offsets (positive = lyrics earlier), per track and version

    /// Each version has its own timing, so a newly picked one doesn't inherit another's offset. A migrated offset
    /// whose version wasn't known (`""`) is claimed by the first version asked for.
    public func offset(for videoId: String, version: String) -> TimeInterval? {
        if let v = queryDouble("SELECT offset FROM version_offsets WHERE video_id = ? AND version_id = ?", [videoId, version]) {
            return v
        }
        guard !version.isEmpty,
              let legacy = queryDouble("SELECT offset FROM version_offsets WHERE video_id = ? AND version_id = ''", [videoId])
        else { return nil }
        run("DELETE FROM version_offsets WHERE video_id = ? AND version_id = ''", [.text(videoId)])
        setOffset(legacy, for: videoId, version: version)
        return legacy
    }

    public func setOffset(_ offset: TimeInterval, for videoId: String, version: String) {
        if abs(offset) < 0.0001 {
            run("DELETE FROM version_offsets WHERE video_id = ? AND version_id = ?", [.text(videoId), .text(version)])
        } else {
            run("INSERT OR REPLACE INTO version_offsets (video_id, version_id, offset) VALUES (?, ?, ?)",
                [.text(videoId), .text(version), .real(offset)])
        }
    }

    // MARK: Pinned versions

    /// The pin that hides lyrics for a track ("No Lyrics for This Song").
    public static let noLyricsPin = "none"

    public func pinnedVersionID(for videoId: String) -> String? {
        queryBlob("SELECT version_id FROM pins WHERE video_id = ?", [videoId]).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func setPinnedVersionID(_ id: String?, for videoId: String) {
        if let id {
            run("INSERT OR REPLACE INTO pins (video_id, version_id) VALUES (?, ?)", [.text(videoId), .text(id)])
        } else {
            run("DELETE FROM pins WHERE video_id = ?", [.text(videoId)])
        }
    }

    // MARK: Rejected versions ("Report Wrong Lyrics", kept on this Mac only)

    public func rejectedVersionIDs(for videoId: String) -> Set<String> {
        var out: Set<String> = []
        query("SELECT version_id FROM rejections WHERE video_id = ?", [videoId]) { out.insert(Self.text($0, 0)) }
        return out
    }

    public func addRejection(_ versionID: String, for videoId: String) {
        run("INSERT OR REPLACE INTO rejections (video_id, version_id, updated) VALUES (?, ?, ?)",
            [.text(videoId), .text(versionID), .real(Date().timeIntervalSince1970)])
    }

    public func removeRejection(_ versionID: String, for videoId: String) {
        run("DELETE FROM rejections WHERE video_id = ? AND version_id = ?", [.text(videoId), .text(versionID)])
    }

    // MARK: Text fingerprints (`QTLyricsSanity.fingerprint`) of the lyrics chosen per track

    /// The other tracks (videoId, title, artist) a text with this fingerprint was chosen for.
    public func fingerprintTracks(_ hash: String, excluding videoId: String) -> [(videoId: String, title: String, artist: String)] {
        var out: [(String, String, String)] = []
        query("SELECT video_id, title, artist FROM fingerprints WHERE hash = ? AND video_id != ?", [hash, videoId]) { stmt in
            out.append((Self.text(stmt, 0), Self.text(stmt, 1), Self.text(stmt, 2)))
        }
        return out
    }

    /// The text now chosen for a track (one per track: it replaces what was recorded before).
    public func recordFingerprint(_ hash: String, videoId: String, title: String, artist: String) {
        clearFingerprints(for: videoId)
        run("INSERT OR REPLACE INTO fingerprints (hash, video_id, title, artist) VALUES (?, ?, ?, ?)",
            [.text(hash), .text(videoId), .text(title), .text(artist)])
    }

    /// Nothing is chosen for the track any more (reported, no lyrics found).
    public func clearFingerprints(for videoId: String) {
        run("DELETE FROM fingerprints WHERE video_id = ?", [.text(videoId)])
    }

    // MARK: Aliases

    public func aliasPairs() -> [(String, String)] {
        var out: [(String, String)] = []
        query("SELECT a, b FROM aliases", []) { stmt in
            out.append((Self.text(stmt, 0), Self.text(stmt, 1)))
        }
        return out
    }

    public func addAlias(_ a: String, _ b: String, origin: String) {
        run("INSERT OR IGNORE INTO aliases (a, b, origin) VALUES (?, ?, ?)", [.text(a), .text(b), .text(origin)])
    }

    // MARK: Machine translations

    public func translation(videoId: String, language: String, engine: String) -> [String]? {
        queryBlob("SELECT lines FROM translations WHERE video_id = ? AND language = ? AND engine = ?",
                  [videoId, language, engine]).flatMap { try? decoder.decode([String].self, from: $0) }
    }

    public func storeTranslation(_ lines: [String], videoId: String, language: String, engine: String) {
        guard let data = try? encoder.encode(lines) else { return }
        run("INSERT OR REPLACE INTO translations (video_id, language, engine, lines, updated) VALUES (?, ?, ?, ?, ?)",
            [.text(videoId), .text(language), .text(engine), .blob(data), .real(Date().timeIntervalSince1970)])
    }

    // MARK: Blobs

    public func blob(named name: String) -> (data: Data, updated: Date)? {
        var out: (Data, Date)?
        query("SELECT data, updated FROM blobs WHERE name = ?", [name]) { stmt in
            out = (Self.blob(stmt, 0), Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)))
        }
        return out
    }

    public func setBlob(_ data: Data, named name: String) {
        run("INSERT OR REPLACE INTO blobs (name, data, updated) VALUES (?, ?, ?)",
            [.text(name), .blob(data), .real(Date().timeIntervalSince1970)])
    }

    public func removeBlob(named name: String) {
        run("DELETE FROM blobs WHERE name = ?", [.text(name)])
    }

    // MARK: SQLite plumbing

    private enum Value {
        case text(String), blob(Data), real(Double)
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func prepare(_ sql: String, _ values: [Value]) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard let db, sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        for (i, v) in values.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, Self.transient)
            case .real(let d): sqlite3_bind_double(stmt, idx, d)
            case .blob(let data):
                _ = data.withUnsafeBytes { raw in
                    sqlite3_bind_blob(stmt, idx, raw.baseAddress, Int32(raw.count), Self.transient)
                }
            }
        }
        return stmt
    }

    private func run(_ sql: String, _ values: [Value]) {
        guard let stmt = prepare(sql, values) else { return }
        defer { sqlite3_finalize(stmt) }
        _ = sqlite3_step(stmt)
    }

    private func query(_ sql: String, _ values: [String], row: (OpaquePointer) -> Void) {
        guard let stmt = prepare(sql, values.map { .text($0) }) else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
    }

    private func queryBlob(_ sql: String, _ values: [String]) -> Data? {
        var out: Data?
        query(sql, values) { stmt in out = Self.blob(stmt, 0) }
        return out
    }

    private func queryDouble(_ sql: String, _ values: [String]) -> Double? {
        var out: Double?
        query(sql, values) { stmt in out = sqlite3_column_double(stmt, 0) }
        return out
    }

    private static func text(_ stmt: OpaquePointer, _ col: Int32) -> String {
        sqlite3_column_text(stmt, col).map { String(cString: $0) } ?? ""
    }

    private static func blob(_ stmt: OpaquePointer, _ col: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(stmt, col))
        guard count > 0, let p = sqlite3_column_blob(stmt, col) else { return Data() }
        return Data(bytes: p, count: count)
    }
}

/// Owns the sqlite3 handle; only the owning actor uses it, the class just closes it on release.
final class QTSQLiteConnection: @unchecked Sendable {
    let handle: OpaquePointer

    init(_ handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        sqlite3_close_v2(handle)
    }
}

public enum QTLyricsCacheError: Error, Sendable {
    case sqlite(String)
}
