import Foundation
import QTCore
import SQLite3

/// What the resolver stores per video: the chosen document, the other versions for the
/// "Wrong lyrics? / Other versions (n)" menu, and the source configuration it was resolved under.
public struct QTLyricsCacheEntry: Sendable, Hashable, Codable {
    public var videoId: String
    /// nil = nothing found (negative cache; shorter lifetime).
    public var document: QTLyricsDocument?
    public var versions: [QTLyricsVersion]
    public var chosenID: String?
    public var attribution: String?
    /// Fingerprint of the enabled sources; a different set triggers a fresh lookup.
    public var sourcesKey: String
    public var updated: Date

    public init(videoId: String, document: QTLyricsDocument?, versions: [QTLyricsVersion], chosenID: String?,
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

/// SQLite store (system `sqlite3`, no dependencies) for lyrics keyed by videoId, per-track offsets,
/// pinned versions, learned aliases, machine translations and small blobs (the AMLL index).
/// Offsets, pins and aliases are user data, so the default file lives in Application Support, not Caches.
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
        let schema = """
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;
        CREATE TABLE IF NOT EXISTS lyrics (video_id TEXT PRIMARY KEY, entry BLOB NOT NULL, updated REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS offsets (video_id TEXT PRIMARY KEY, offset REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS pins (video_id TEXT PRIMARY KEY, version_id TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS aliases (a TEXT NOT NULL, b TEXT NOT NULL, origin TEXT, PRIMARY KEY (a, b));
        CREATE TABLE IF NOT EXISTS translations (video_id TEXT NOT NULL, language TEXT NOT NULL, engine TEXT NOT NULL,
            lines BLOB NOT NULL, updated REAL NOT NULL, PRIMARY KEY (video_id, language, engine));
        CREATE TABLE IF NOT EXISTS blobs (name TEXT PRIMARY KEY, data BLOB NOT NULL, updated REAL NOT NULL);
        """
        if sqlite3_exec(handle, schema, nil, nil, nil) != SQLITE_OK {
            throw QTLyricsCacheError.sqlite(String(cString: sqlite3_errmsg(handle)))
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

    // MARK: Offsets (positive = lyrics earlier)

    public func offset(for videoId: String) -> TimeInterval? {
        queryDouble("SELECT offset FROM offsets WHERE video_id = ?", [videoId])
    }

    public func setOffset(_ offset: TimeInterval, for videoId: String) {
        if abs(offset) < 0.0001 {
            run("DELETE FROM offsets WHERE video_id = ?", [.text(videoId)])
        } else {
            run("INSERT OR REPLACE INTO offsets (video_id, offset) VALUES (?, ?)", [.text(videoId), .real(offset)])
        }
    }

    // MARK: Pinned versions

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
