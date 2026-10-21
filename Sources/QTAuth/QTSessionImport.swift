import Foundation
import SQLite3

/// Reading a session the user exported from their own browser, for `QTAuthController.importSession`: a Netscape
/// `cookies.txt` file or a Firefox profile's `cookies.sqlite`. Both readers return only Google/YouTube cookies on the
/// auth allowlist (`QTAuthSession.authCookieNames`); everything else in the file is skipped as it's read. Chrome
/// (its Keychain-encrypted, device-bound cookies) and Safari (Full Disk Access) aren't supported.
public enum QTCookieImport {
    public enum Failure: Error, Equatable, Sendable {
        /// The file or database couldn't be read (permissions, gone, not SQLite).
        case unreadable
        /// Bigger than any cookies export (`maxFileSize`): not read at all.
        case tooLarge
        /// Firefox's database didn't have the table or columns expected.
        case unexpectedFormat
        /// macOS kept the app out of another app's data (privacy protection); picking the folder in the open panel
        /// grants access.
        case notPermitted
        /// The Firefox profile folder has no `cookies.sqlite`.
        case noDatabase
    }

    /// Larger files aren't cookie exports.
    public static let maxFileSize = 20 * 1024 * 1024

    /// A cookie the import may take: on the auth allowlist and set for google.com / youtube.com.
    static func admits(_ cookie: QTCookie) -> Bool {
        QTAuthSession.authCookieNames.contains(cookie.name) && cookie.isGoogleOrYouTube
    }

    // MARK: cookies.txt

    /// Netscape `cookies.txt` (curl, yt-dlp, the "cookies.txt" browser extensions): one cookie per line, seven
    /// tab-separated fields — domain, include-subdomains flag, path, secure, expiry (Unix seconds, 0 = session),
    /// name, value. `#` starts a comment, except the `#HttpOnly_` prefix that marks an HttpOnly cookie's domain.
    public static func parseNetscape(_ text: String) -> [QTCookie] {
        var cookies: [QTCookie] = []
        for raw in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            var line = Substring(raw)
            var httpOnly = false
            if line.hasPrefix("#HttpOnly_") {
                httpOnly = true
                line = line.dropFirst("#HttpOnly_".count)
            } else if line.hasPrefix("#") {
                continue
            }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 7 else { continue }
            var domain = String(fields[0]).trimmingCharacters(in: .whitespaces)
            let includeSubdomains = fields[1].uppercased() == "TRUE"
            // A domain cookie is written with its leading dot; some exporters only set the flag.
            if includeSubdomains, !domain.hasPrefix(".") { domain = "." + domain }
            let expirySeconds = Double(fields[4].trimmingCharacters(in: .whitespaces)) ?? 0
            let value = fields[6...].joined(separator: "\t").trimmingCharacters(in: .whitespaces)
            let cookie = QTCookie(name: String(fields[5]), value: value, domain: domain,
                                  path: fields[2].isEmpty ? "/" : String(fields[2]),
                                  expires: expirySeconds > 0 ? Date(timeIntervalSince1970: expirySeconds) : nil,
                                  isSecure: fields[3].uppercased() == "TRUE", isHTTPOnly: httpOnly)
            if admits(cookie) { cookies.append(cookie) }
        }
        return cookies
    }

    /// Reads a `cookies.txt` the user picked.
    public static func readNetscape(at url: URL) throws -> [QTCookie] {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxFileSize else { throw Failure.tooLarge }
        guard let data = try? Data(contentsOf: url) else { throw Failure.unreadable }
        return parseNetscape(String(decoding: data, as: UTF8.self))
    }
}

// MARK: - Firefox

/// A Firefox profile with a cookie database.
public struct QTFirefoxProfile: Hashable, Sendable, Identifiable {
    /// The profile's name in Firefox (`profiles.ini`), e.g. "default-release".
    public var name: String
    public var directory: URL
    /// The profile this Firefox install opens by default.
    public var isDefault: Bool

    public var id: URL { directory }
    public var cookiesDatabase: URL { directory.appending(path: "cookies.sqlite") }

    public init(name: String, directory: URL, isDefault: Bool = false) {
        self.name = name
        self.directory = directory
        self.isDefault = isDefault
    }
}

/// Firefox keeps cookies in plain SQLite (`<profile>/cookies.sqlite`, no Keychain prompt), so its sessions can be
/// imported. Firefox holds the database open in WAL mode while it runs: the reader copies the database and its
/// `-wal` into a private temporary folder, reads the copy and deletes it at once.
public enum QTFirefoxCookies {
    /// `~/Library/Application Support/Firefox`.
    public static var applicationSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Firefox",
                                                                 directoryHint: .isDirectory)
    }

    /// Profiles with a cookie database: those `profiles.ini` names, then any other folder under `Profiles/`. The
    /// install's default profile first, then by name.
    public static func profiles(in root: URL = applicationSupport, fileManager: FileManager = .default) -> [QTFirefoxProfile] {
        var found: [QTFirefoxProfile] = []
        if let ini = try? String(contentsOf: root.appending(path: "profiles.ini"), encoding: .utf8) {
            found = profiles(ini: ini, root: root)
        }
        let profilesDir = root.appending(path: "Profiles", directoryHint: .isDirectory)
        let folders = (try? fileManager.contentsOfDirectory(at: profilesDir, includingPropertiesForKeys: nil)) ?? []
        let known = Set(found.map { $0.directory.standardizedFileURL.path })
        for folder in folders where !known.contains(folder.standardizedFileURL.path) {
            // Folders are "<salt>.<name>".
            let base = folder.lastPathComponent
            let name = base.split(separator: ".", maxSplits: 1).dropFirst().first.map(String.init) ?? base
            found.append(QTFirefoxProfile(name: name, directory: folder))
        }
        return found
            .filter { fileManager.fileExists(atPath: $0.cookiesDatabase.path) }
            .sorted { ($0.isDefault ? 0 : 1, $0.name.lowercased()) < ($1.isDefault ? 0 : 1, $1.name.lowercased()) }
    }

    /// `profiles.ini`: `[ProfileN]` sections (`Name`, `Path`, `IsRelative`, `Default=1`) and `[Install…]` sections
    /// whose `Default` names the profile that install opens.
    static func profiles(ini: String, root: URL) -> [QTFirefoxProfile] {
        var sections: [(name: String, keys: [String: String])] = []
        for raw in ini.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                sections.append((String(line.dropFirst().dropLast()), [:]))
            } else if let eq = line.firstIndex(of: "="), !sections.isEmpty {
                sections[sections.count - 1].keys[String(line[..<eq])] = String(line[line.index(after: eq)...])
            }
        }
        let installDefaults = Set(sections.filter { $0.name.hasPrefix("Install") }.compactMap { $0.keys["Default"] })
        return sections.filter { $0.name.hasPrefix("Profile") }.compactMap { section in
            guard let path = section.keys["Path"], !path.isEmpty else { return nil }
            let relative = section.keys["IsRelative"] != "0"
            let dir = relative ? root.appending(path: path, directoryHint: .isDirectory)
                : URL(fileURLWithPath: path, isDirectory: true)
            let isDefault = installDefaults.isEmpty ? section.keys["Default"] == "1" : installDefaults.contains(path)
            return QTFirefoxProfile(name: section.keys["Name"] ?? dir.lastPathComponent, directory: dir, isDefault: isDefault)
        }
    }

    /// The profile's Google/YouTube auth cookies (default container only), read from a private copy that's deleted
    /// before this returns.
    public static func cookies(in profile: QTFirefoxProfile,
                               temporaryDirectory: URL = FileManager.default.temporaryDirectory,
                               fileManager: FileManager = .default) throws -> [QTCookie] {
        let source = profile.cookiesDatabase
        do {
            _ = try source.checkResourceIsReachable()
        } catch {
            throw isPermissionError(error) ? QTCookieImport.Failure.notPermitted : QTCookieImport.Failure.noDatabase
        }
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= 8 * QTCookieImport.maxFileSize else { throw QTCookieImport.Failure.tooLarge }
        let scratch = temporaryDirectory.appending(path: "qtube-import-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
        } catch {
            throw QTCookieImport.Failure.unreadable
        }
        // The copy holds the whole profile's cookies in plain text: it never outlives this call.
        defer { try? fileManager.removeItem(at: scratch) }
        let copy = scratch.appending(path: "cookies.sqlite")
        do {
            try fileManager.copyItem(at: source, to: copy)
        } catch {
            throw isPermissionError(error) ? QTCookieImport.Failure.notPermitted : QTCookieImport.Failure.unreadable
        }
        // Recent changes live in the write-ahead log until Firefox checkpoints it; SQLite folds it into the copy on
        // open. The shared-memory index (`-shm`) is rebuilt from it.
        let wal = URL(fileURLWithPath: source.path + "-wal")
        if fileManager.fileExists(atPath: wal.path) {
            try? fileManager.copyItem(at: wal, to: URL(fileURLWithPath: copy.path + "-wal"))
        }
        return try readDatabase(at: copy)
    }

    /// EPERM / EACCES, however Foundation wraps it.
    static func isPermissionError(_ error: any Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoPermissionError { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EPERM) || ns.code == Int(EACCES) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError { return isPermissionError(underlying) }
        return false
    }

    /// Reads `moz_cookies` from a Firefox cookie database (a copy: opening it may fold the WAL in).
    static func readDatabase(at url: URL) throws -> [QTCookie] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw QTCookieImport.Failure.unreadable
        }
        defer { sqlite3_close(db) }
        // `originAttributes = ''`: the default container only — not containers, not partitioned third-party cookies
        // (private windows are never written to disk).
        let filter = "FROM moz_cookies WHERE originAttributes = '' AND (host LIKE '%google.com' OR host LIKE '%youtube.com')"
        var statement: OpaquePointer?
        var hasSameSite = true
        if sqlite3_prepare_v2(db, "SELECT host, name, value, path, expiry, isSecure, isHttpOnly, sameSite \(filter)", -1,
                              &statement, nil) != SQLITE_OK {
            // Profiles from before Firefox 60 have no `sameSite` column.
            sqlite3_finalize(statement)
            statement = nil
            hasSameSite = false
            guard sqlite3_prepare_v2(db, "SELECT host, name, value, path, expiry, isSecure, isHttpOnly \(filter)", -1,
                                     &statement, nil) == SQLITE_OK else {
                sqlite3_finalize(statement)
                let code = sqlite3_errcode(db)
                throw code == SQLITE_NOTADB || code == SQLITE_CORRUPT ? QTCookieImport.Failure.unreadable
                    : QTCookieImport.Failure.unexpectedFormat
            }
        }
        defer { sqlite3_finalize(statement) }
        func text(_ i: Int32) -> String {
            sqlite3_column_text(statement, i).map { String(cString: $0) } ?? ""
        }
        var cookies: [QTCookie] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw QTCookieImport.Failure.unreadable }
            let cookie = QTCookie(name: text(1), value: text(2), domain: text(0), path: text(3).isEmpty ? "/" : text(3),
                                  expires: expiryDate(sqlite3_column_int64(statement, 4)),
                                  isSecure: sqlite3_column_int(statement, 5) != 0,
                                  isHTTPOnly: sqlite3_column_int(statement, 6) != 0,
                                  sameSite: hasSameSite ? sameSite(sqlite3_column_int(statement, 7)) : nil)
            if QTCookieImport.admits(cookie) { cookies.append(cookie) }
        }
        return cookies
    }

    /// `expiry` is Unix seconds; newer Firefox versions store milliseconds. Anything past the year 5000 in seconds is
    /// read as milliseconds. 0 or less: a session cookie.
    static func expiryDate(_ raw: Int64) -> Date? {
        guard raw > 0 else { return nil }
        let seconds = raw > 100_000_000_000 ? Double(raw) / 1000 : Double(raw)
        return Date(timeIntervalSince1970: seconds)
    }

    /// Firefox's `nsICookie` values: 1 lax, 2 strict; 0 (none) and 256 (unset) carry no policy.
    static func sameSite(_ raw: Int32) -> String? {
        switch raw {
        case 1: "lax"
        case 2: "strict"
        default: nil
        }
    }
}
