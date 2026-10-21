import Foundation
import JavaScriptCore
import SQLite3
import Testing
import WebKit
@testable import QTAuth
@testable import QTInnerTube

/// The sign-in window's page rules and the session import, offline: the WebAuthn-hiding script (JavaScriptCore with a
/// fake `navigator`, then a real `WKWebView` on a local page), the Safari user agent, the address strip's host checks,
/// the cookies.txt and Firefox readers (a fixture database built here, in a temporary folder) and the controller's
/// import / sign-out paths. Never Google, never the user's browsers.
@Suite struct SignInPageTests {
    // MARK: WebAuthn

    /// A browser-like global: `PublicKeyCredential` as a plain (configurable) window property and a
    /// `CredentialsContainer` whose prototype answers like the platform.
    static let fakeBrowser = """
    var window = globalThis;
    globalThis.PublicKeyCredential = function PublicKeyCredential() {};
    function DOMException(message, name) { this.message = message; this.name = name; }
    function CredentialsContainer() {}
    CredentialsContainer.prototype.get = function (o) { return Promise.resolve("platform-get"); };
    CredentialsContainer.prototype.create = function (o) { return Promise.resolve("platform-create"); };
    globalThis.navigator = { credentials: new CredentialsContainer() };
    var results = {};
    """

    @Test func hidingScriptRemovesWebAuthn() throws {
        let js = try #require(JSContext())
        js.evaluateScript(Self.fakeBrowser)
        #expect(js.evaluateScript("typeof PublicKeyCredential").toString() == "function")
        js.evaluateScript(QTSignInPage.hideWebAuthnScript)
        #expect(js.exception == nil)
        #expect(js.evaluateScript("typeof window.PublicKeyCredential").toString() == "undefined")
        // A page can't put it back.
        js.evaluateScript("window.PublicKeyCredential = function () {};")
        #expect(js.evaluateScript("typeof window.PublicKeyCredential").toString() == "undefined")
        js.evaluateScript("""
        navigator.credentials.get({ publicKey: { challenge: 1 } }).then(v => results.get = v, e => results.get = e.name);
        navigator.credentials.create({ publicKey: {} }).then(v => results.create = v, e => results.create = e.name);
        navigator.credentials.get({ password: true }).then(v => results.password = v, e => results.password = e.name);
        """)
        // Microtasks drain when the evaluation above returns.
        #expect(js.evaluateScript("results.get").toString() == "NotAllowedError")
        #expect(js.evaluateScript("results.create").toString() == "NotAllowedError")
        #expect(js.evaluateScript("results.password").toString() == "platform-get", "other credential kinds pass through")
    }

    @Test func hidingScriptSurvivesAPageWithoutCredentials() throws {
        let js = try #require(JSContext())
        js.evaluateScript("var window = globalThis; globalThis.navigator = {};")
        js.evaluateScript(QTSignInPage.hideWebAuthnScript)
        #expect(js.exception == nil)
        #expect(js.evaluateScript("typeof PublicKeyCredential").toString() == "undefined")
    }

    /// The real thing: a `WKWebView` on a local page (no network). Without the script WebKit exposes
    /// `PublicKeyCredential`; with the sign-in configuration it's gone, in subframes too, and the user agent is
    /// Safari's with the given version.
    @MainActor
    @Test func signInConfigurationHidesWebAuthnInWebKit() async throws {
        let plain = WKWebViewConfiguration()
        plain.websiteDataStore = .nonPersistent()
        let before = try await Self.evaluate("typeof PublicKeyCredential", configuration: plain)
        let config = QTSignInPage.configuration(dataStore: .nonPersistent(), safariVersion: "26.1")
        #expect(config.userContentController.userScripts.contains {
            $0.injectionTime == .atDocumentStart && !$0.isForMainFrameOnly && $0.source == QTSignInPage.hideWebAuthnScript
        })
        let after = try await Self.evaluate(
            "typeof PublicKeyCredential + '|' + document.querySelector('iframe').contentWindow.eval('typeof PublicKeyCredential') + '|' + navigator.userAgent",
            configuration: config)
        let parts = after.split(separator: "|").map(String.init)
        #expect(parts.count == 3)
        #expect(before == "function", "WebKit exposes WebAuthn to a secure page without the script")
        #expect(parts.first == "undefined")
        #expect(parts.dropFirst().first == "undefined", "subframes too")
        #expect(parts.last?.hasSuffix(" Version/26.1 Safari/605.1.15") == true)
        #expect(parts.last?.hasPrefix("Mozilla/5.0 (Macintosh; ") == true)
    }

    @MainActor
    static func evaluate(_ script: String, configuration: WKWebViewConfiguration) async throws -> String {
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: configuration)
        let loaded = QTLoadWaiter()
        view.navigationDelegate = loaded
        // A secure context (WebAuthn exists only there) without the network: the HTML is given, nothing is fetched, and
        // `.invalid` never resolves.
        view.loadHTMLString("<!doctype html><title>t</title><iframe srcdoc='<p>x'></iframe>",
                            baseURL: URL(string: "https://qtube.invalid/"))
        try await loaded.wait()
        try await Task.sleep(for: .milliseconds(100)) // the srcdoc frame
        let value = try await view.evaluateJavaScript(script)
        return (value as? String) ?? "\(value ?? "nil")"
    }

    // MARK: User agent

    @Test func safariVersionFromInfoPlist() {
        #expect(QTSafariUserAgent.version(fromInfo: ["CFBundleShortVersionString": "26.0"]) == "26.0")
        #expect(QTSafariUserAgent.version(fromInfo: ["CFBundleShortVersionString": "26.0.1"]) == "26.0.1")
        #expect(QTSafariUserAgent.version(fromInfo: ["CFBundleShortVersionString": "27"]) == "27.0")
        for junk in ["", "26.0 beta", "x.1", "26..1", "1.0", "26.0.1.2", "100.0", "26.0;evil"] {
            #expect(QTSafariUserAgent.version(fromInfo: ["CFBundleShortVersionString": junk]) == nil, "\(junk)")
        }
        #expect(QTSafariUserAgent.version(fromInfo: nil) == nil)
        #expect(QTSafariUserAgent.version(fromInfo: ["CFBundleShortVersionString": 26]) == nil)
    }

    @Test func safariVersionFallsBackToTheOS() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "qt-ua-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plist = dir.appending(path: "Info.plist")
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "26.2"], format: .xml, options: 0)
            .write(to: plist)
        let os26 = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        let os15 = OperatingSystemVersion(majorVersion: 15, minorVersion: 6, patchVersion: 0)
        #expect(QTSafariUserAgent.installedVersion(infoPlist: plist, osVersion: os15) == "26.2")
        let missing = dir.appending(path: "missing.plist")
        #expect(QTSafariUserAgent.installedVersion(infoPlist: missing, osVersion: os26) == "26.0")
        #expect(QTSafariUserAgent.installedVersion(infoPlist: missing, osVersion: os15) == "18.0")
    }

    @Test func userAgentIsSafarisShape() {
        #expect(QTSafariUserAgent.applicationName(version: "26.0") == "Version/26.0 Safari/605.1.15")
        #expect(QTSafariUserAgent.userAgent(version: "26.0")
            == "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15")
        // The API client and players present the same Safari as the sign-in window.
        #expect(QTInnerTubeConfiguration.defaultUserAgent == QTSafariUserAgent.userAgent(version: QTSafariUserAgent.current))
        #expect(QTSafariUserAgent.version(fromInfo: ["CFBundleShortVersionString": QTSafariUserAgent.current]) != nil)
    }

    // MARK: Address strip and links

    @Test func addressStripTrustsOnlyGoogleOverHTTPS() {
        func address(_ s: String?, secure: Bool = true) -> QTSignInAddress {
            QTSignInAddress(url: s.flatMap(URL.init(string:)), hasOnlySecureContent: secure)
        }
        #expect(address("https://accounts.google.com/v3/signin") == .secure(host: "accounts.google.com"))
        #expect(address("https://ACCOUNTS.Google.com/") == .secure(host: "accounts.google.com"))
        #expect(address("https://music.youtube.com/") == .secure(host: "music.youtube.com"))
        #expect(address("https://google.com./") == .secure(host: "google.com."))
        #expect(address("https://accounts.google.com/", secure: false) == .notSecure(host: "accounts.google.com"))
        #expect(address("http://accounts.google.com/") == .notSecure(host: "accounts.google.com"))
        #expect(address("https://accounts.google.com.evil.example/") == .otherSite(host: "accounts.google.com.evil.example"))
        #expect(address("https://evilgoogle.com/") == .otherSite(host: "evilgoogle.com"))
        #expect(address("https://notyoutube.com/") == .otherSite(host: "notyoutube.com"))
        #expect(address("https://sso.example.com/saml") == .otherSite(host: "sso.example.com"))
        #expect(address(nil) == .loading)
        #expect(address("about:blank") == .loading)
        #expect(address("https://accounts.google.com/").isTrusted)
        #expect(!address("https://sso.example.com/").isTrusted)
    }

    @Test func onlyWebLinksLeaveForTheBrowser() {
        #expect(QTSignInPage.opensInBrowser(URL(string: "https://support.google.com/accounts/answer/1")))
        #expect(QTSignInPage.opensInBrowser(URL(string: "http://example.com/")))
        #expect(!QTSignInPage.opensInBrowser(URL(string: "javascript:alert(1)")))
        #expect(!QTSignInPage.opensInBrowser(URL(string: "file:///etc/passwd")))
        #expect(!QTSignInPage.opensInBrowser(URL(string: "mailto:a@example.com")))
        #expect(!QTSignInPage.opensInBrowser(URL(string: "about:blank")))
        #expect(!QTSignInPage.opensInBrowser(nil))
    }
}

/// Waits for a web view's first load.
@MainActor
final class QTLoadWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, any Error>?
    private var done = false

    func wait() async throws {
        if done { return }
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    private func finish(_ error: (any Error)?) {
        done = true
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(nil) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { finish(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finish(error)
    }
}

// MARK: - Import

@Suite struct SessionImportTests {
    static let future = Int64(Date().timeIntervalSince1970) + 30 * 86_400

    static var cookiesTxt: String {
        """
        # Netscape HTTP Cookie File
        # https://curl.se/docs/http-cookies.html
        # This file was generated by a cookies.txt extension. Edit at your own risk.\r
        .youtube.com\tTRUE\t/\tTRUE\t\(future)\tSAPISID\tFAKE-SAPISID\r
        .youtube.com\tTRUE\t/\tTRUE\t\(future)\t__Secure-3PAPISID\tFAKE-3PAPISID
        #HttpOnly_.youtube.com\tTRUE\t/\tFALSE\t\(future)\tHSID\tFAKE-HSID
        youtube.com\tTRUE\t/\tFALSE\t\(future)\tSID\tFAKE-SID
        #HttpOnly_.youtube.com\tTRUE\t/\tTRUE\t\(future)\t__Secure-1PSIDTS\tsidts-FAKE\twith-tab
        .google.com\tTRUE\t/\tTRUE\t0\tSAPISID\tFAKE-SESSION-ONLY
        music.youtube.com\tFALSE\t/\tTRUE\t\(future)\tLOGIN_INFO\tFAKE-LOGIN

        .youtube.com\tTRUE\t/\tTRUE\t\(future)\tVISITOR_INFO1_LIVE\tvisitor
        .example.com\tTRUE\t/\tTRUE\t\(future)\tSID\tother-site
        .notyoutube.com\tTRUE\t/\tTRUE\t\(future)\tSID\tlookalike
        .youtube.com\tTRUE\t/\tTRUE
        # .youtube.com\tTRUE\t/\tTRUE\t\(future)\tSSID\tcommented-out
        """
    }

    @Test func netscapeFileKeepsOnlyAllowListedGoogleCookies() throws {
        let cookies = QTCookieImport.parseNetscape(Self.cookiesTxt)
        let byName = Dictionary(grouping: cookies, by: \.name)
        #expect(Set(cookies.map(\.name)) == ["SAPISID", "__Secure-3PAPISID", "HSID", "SID", "__Secure-1PSIDTS", "LOGIN_INFO"])
        #expect(!cookies.contains { $0.value == "other-site" || $0.value == "lookalike" || $0.value == "visitor" })
        #expect(!cookies.contains { $0.value == "commented-out" })
        let hsid = try #require(byName["HSID"]?.first)
        #expect(hsid.isHTTPOnly && !hsid.isSecure && hsid.domain == ".youtube.com")
        // The flag makes a domain cookie even without the dot; host-only stays host-only.
        #expect(byName["SID"]?.first?.domain == ".youtube.com")
        #expect(byName["LOGIN_INFO"]?.first?.domain == "music.youtube.com")
        // CRLF line ends are stripped; a tab inside the value is kept.
        #expect(byName["SAPISID"]?.contains { $0.value == "FAKE-SAPISID" } == true)
        #expect(byName["__Secure-1PSIDTS"]?.first?.value == "sidts-FAKE\twith-tab")
        #expect(byName["SAPISID"]?.first { $0.domain == ".google.com" }?.expires == nil, "0 = session cookie")
        #expect(byName["SID"]?.first?.expires == Date(timeIntervalSince1970: TimeInterval(Self.future)))
        #expect(QTAuthSession(cookies: QTAuthSession.filtered(cookies)).isComplete)
    }

    @Test func netscapeFileWithoutALoginIsIncomplete() {
        let cookies = QTCookieImport.parseNetscape(".youtube.com\tTRUE\t/\tTRUE\t\(Self.future)\tPREF\tf6=8\n")
        #expect(cookies.count == 1)
        #expect(!QTAuthSession(cookies: QTAuthSession.filtered(cookies)).isComplete)
        #expect(QTCookieImport.parseNetscape("not a cookies file\n{\"json\": true}").isEmpty)
    }

    @Test func oversizedFilesAreNotRead() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let big = dir.appending(path: "cookies.txt")
        #expect(FileManager.default.createFile(atPath: big.path, contents: nil))
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(QTCookieImport.maxFileSize + 1))
        try handle.close()
        #expect(throws: QTCookieImport.Failure.tooLarge) { try QTCookieImport.readNetscape(at: big) }
        #expect(throws: QTCookieImport.Failure.unreadable) {
            try QTCookieImport.readNetscape(at: dir.appending(path: "missing.txt"))
        }
        let small = dir.appending(path: "small.txt")
        try Self.cookiesTxt.write(to: small, atomically: true, encoding: .utf8)
        #expect(try QTCookieImport.readNetscape(at: small).count == 7)
    }

    // MARK: Firefox

    static func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "qt-import-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Firefox's current `moz_cookies` schema.
    static let schema = """
    CREATE TABLE moz_cookies (id INTEGER PRIMARY KEY, originAttributes TEXT NOT NULL DEFAULT '', name TEXT, value TEXT,
      host TEXT, path TEXT, expiry INTEGER, lastAccessed INTEGER, creationTime INTEGER, isSecure INTEGER,
      isHttpOnly INTEGER, inBrowserElement INTEGER DEFAULT 0, sameSite INTEGER DEFAULT 0, rawSameSite INTEGER DEFAULT 0,
      schemeMap INTEGER DEFAULT 0, isPartitionedAttributeSet INTEGER DEFAULT 0,
      CONSTRAINT moz_uniqueid UNIQUE (name, host, path, originAttributes));
    """

    /// A Firefox profile folder; `db` stays open (as Firefox keeps it) so later writes sit in the `-wal` only.
    final class FirefoxFixture {
        let root: URL
        let profile: URL
        var db: OpaquePointer?

        init() throws {
            root = try SessionImportTests.scratch()
            profile = root.appending(path: "Profiles/a1b2c3d4.default-release", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            #expect(sqlite3_open(profile.appending(path: "cookies.sqlite").path, &db) == SQLITE_OK)
            exec("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
            exec(SessionImportTests.schema)
        }

        deinit {
            sqlite3_close(db)
            try? FileManager.default.removeItem(at: root)
        }

        func exec(_ sql: String) {
            #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "\(String(cString: sqlite3_errmsg(db)))")
        }

        func insert(_ name: String, _ value: String, host: String, expiry: Int64 = SessionImportTests.future,
                    origin: String = "", secure: Int = 1, httpOnly: Int = 0, sameSite: Int = 0) {
            exec("""
            INSERT INTO moz_cookies (originAttributes, name, value, host, path, expiry, lastAccessed, creationTime, isSecure,
              isHttpOnly, sameSite) VALUES ('\(origin)', '\(name)', '\(value)', '\(host)', '/', \(expiry), 0, 0, \(secure),
              \(httpOnly), \(sameSite));
            """)
        }
    }

    @Test func firefoxProfileCookiesIncludingTheWriteAheadLog() throws {
        let fx = try FirefoxFixture()
        fx.insert("SAPISID", "FAKE-SAPISID", host: ".youtube.com", sameSite: 1)
        fx.insert("HSID", "FAKE-HSID", host: ".youtube.com", secure: 0, httpOnly: 1)
        fx.insert("SAPISID", "FAKE-SAPISID", host: ".google.com", sameSite: 2)
        fx.insert("VISITOR_INFO1_LIVE", "visitor", host: ".youtube.com")
        fx.insert("SID", "other-site", host: ".example.com")
        fx.insert("SID", "lookalike", host: ".notyoutube.com")
        fx.insert("SID", "container", host: ".youtube.com", origin: "^userContextId=2")
        fx.insert("SID", "partitioned", host: ".youtube.com", origin: "^partitionKey=%28https%2Cexample.com%29")
        // Newer Firefox: expiry in milliseconds.
        fx.insert("SID", "FAKE-SID", host: ".youtube.com", expiry: SessionImportTests.future * 1000)
        fx.insert("__Secure-3PSID", "FAKE-3PSID", host: ".youtube.com", expiry: 0)
        let wal = URL(fileURLWithPath: fx.profile.appending(path: "cookies.sqlite").path + "-wal")
        #expect(FileManager.default.fileExists(atPath: wal.path), "the rows are still in the write-ahead log")
        let before = try FileManager.default.contentsOfDirectory(atPath: fx.profile.path).sorted()

        let temp = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: temp) }
        let profile = QTFirefoxProfile(name: "default-release", directory: fx.profile)
        let cookies = try QTFirefoxCookies.cookies(in: profile, temporaryDirectory: temp)

        #expect(Set(cookies.map { "\($0.name)@\($0.domain)=\($0.value)" }) == [
            "SAPISID@.youtube.com=FAKE-SAPISID", "HSID@.youtube.com=FAKE-HSID", "SAPISID@.google.com=FAKE-SAPISID",
            "SID@.youtube.com=FAKE-SID", "__Secure-3PSID@.youtube.com=FAKE-3PSID",
        ])
        let sid = try #require(cookies.first { $0.name == "SID" })
        #expect(sid.expires == Date(timeIntervalSince1970: TimeInterval(SessionImportTests.future)))
        #expect(cookies.first { $0.name == "__Secure-3PSID" }?.expires == nil)
        let hsid = try #require(cookies.first { $0.name == "HSID" })
        #expect(hsid.isHTTPOnly && !hsid.isSecure)
        #expect(cookies.first { $0.name == "SAPISID" && $0.domain == ".youtube.com" }?.sameSite == "lax")
        #expect(cookies.first { $0.name == "SAPISID" && $0.domain == ".google.com" }?.sameSite == "strict")
        #expect(QTAuthSession(cookies: QTAuthSession.filtered(cookies)).isComplete)
        // The private copy is gone; Firefox's own files are untouched.
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fx.profile.path).sorted() == before)
    }

    @Test func firefoxReaderRejectsWhatIsntACookieDatabase() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let profile = QTFirefoxProfile(name: "broken", directory: dir)
        #expect(throws: QTCookieImport.Failure.noDatabase) {
            try QTFirefoxCookies.cookies(in: profile, temporaryDirectory: dir)
        }
        try Data("this is not sqlite, just text that is long enough to not be an empty database....".utf8)
            .write(to: profile.cookiesDatabase)
        #expect(throws: QTCookieImport.Failure.unreadable) {
            try QTFirefoxCookies.cookies(in: profile, temporaryDirectory: dir)
        }
        // A SQLite file without Firefox's table.
        try FileManager.default.removeItem(at: profile.cookiesDatabase)
        var db: OpaquePointer?
        sqlite3_open(profile.cookiesDatabase.path, &db)
        sqlite3_exec(db, "CREATE TABLE other (x INTEGER);", nil, nil, nil)
        sqlite3_close(db)
        #expect(throws: QTCookieImport.Failure.unexpectedFormat) {
            try QTFirefoxCookies.cookies(in: profile, temporaryDirectory: dir)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["cookies.sqlite"])
    }

    /// A database the app may not read (macOS privacy protection looks the same: EPERM) says so, so the pane can
    /// offer the open panel.
    @Test func firefoxDatabaseWithoutPermission() throws {
        let fx = try FirefoxFixture()
        fx.insert("SID", "FAKE-SID", host: ".youtube.com")
        let db = fx.profile.appending(path: "cookies.sqlite")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: db.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: db.path) }
        let temp = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: temp) }
        #expect(throws: QTCookieImport.Failure.notPermitted) {
            try QTFirefoxCookies.cookies(in: QTFirefoxProfile(name: "locked", directory: fx.profile), temporaryDirectory: temp)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.path).isEmpty)
        #expect(QTFirefoxCookies.isPermissionError(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)))
        #expect(QTFirefoxCookies.isPermissionError(NSError(domain: NSCocoaErrorDomain, code: 1, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)),
        ])))
        #expect(!QTFirefoxCookies.isPermissionError(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)))
    }

    @Test func firefoxProfilesFromProfilesIni() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        for folder in ["Profiles/aaaa.default", "Profiles/bbbb.default-release", "Profiles/cccc.work", "Profiles/dddd.empty"] {
            let dir = root.appending(path: folder, directoryHint: .isDirectory)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if !folder.hasSuffix("empty") { fm.createFile(atPath: dir.appending(path: "cookies.sqlite").path, contents: Data()) }
        }
        let elsewhere = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        fm.createFile(atPath: elsewhere.appending(path: "cookies.sqlite").path, contents: Data())
        try """
        [Install4F96D1932A9F858E]
        Default=Profiles/bbbb.default-release
        Locked=1

        [Profile1]
        Name=default
        IsRelative=1
        Path=Profiles/aaaa.default
        Default=1

        [Profile0]
        Name=default-release
        IsRelative=1
        Path=Profiles/bbbb.default-release

        [Profile2]
        Name=Elsewhere
        IsRelative=0
        Path=\(elsewhere.path)

        [Profile3]
        Name=Gone
        IsRelative=1
        Path=Profiles/zzzz.gone

        [General]
        StartWithLastProfile=1
        Version=2
        """.write(to: root.appending(path: "profiles.ini"), atomically: true, encoding: .utf8)
        let profiles = QTFirefoxCookies.profiles(in: root)
        #expect(profiles.map(\.name) == ["default-release", "default", "Elsewhere", "work"])
        #expect(profiles.first?.isDefault == true)
        #expect(profiles.filter(\.isDefault).count == 1)
        #expect(QTFirefoxCookies.profiles(in: root.appending(path: "nothing-here")).isEmpty)
    }

    @Test func firefoxExpiryAndSameSite() {
        #expect(QTFirefoxCookies.expiryDate(0) == nil)
        #expect(QTFirefoxCookies.expiryDate(1_900_000_000) == Date(timeIntervalSince1970: 1_900_000_000))
        #expect(QTFirefoxCookies.expiryDate(1_900_000_000_000) == Date(timeIntervalSince1970: 1_900_000_000))
        #expect(QTFirefoxCookies.sameSite(1) == "lax")
        #expect(QTFirefoxCookies.sameSite(2) == "strict")
        #expect(QTFirefoxCookies.sameSite(0) == nil)
        #expect(QTFirefoxCookies.sameSite(256) == nil)
    }

    // MARK: Controller

    /// YouTube answers the account read signed out: the imported session isn't kept.
    @MainActor
    @Test func importRejectedByYouTubeKeepsNothing() async throws {
        let memory = QTMemorySecureStore()
        let web = QTMemoryWebCookieStore()
        let transport = FakeTransport()
        transport.enqueue("/", data: Data(#"<script>ytcfg.set({"LOGGED_IN":false,"INNERTUBE_CONTEXT_GL":"US"})</script>"#.utf8))
        let client = QTInnerTubeClient(transport: transport, retry: .none, scrapesClientConfig: false, sleep: { _ in })
        let controller = QTAuthController(sessionStore: QTSessionStore(store: memory), cookieStore: web, client: client)
        await controller.restore()
        await #expect(throws: QTAuthError.sessionRejected) {
            try await controller.importSession(cookies: AuthTests.fakeLogin())
        }
        #expect(controller.state == .signedOut)
        #expect(try memory.read() == nil)
        #expect(web.cookies.filter(\.isGoogleOrYouTube).isEmpty)
    }

    /// The account read says signed in: kept, and the account's facts are read as after a sign-in.
    @MainActor
    @Test func importAcceptedReadsTheAccount() async throws {
        let memory = QTMemorySecureStore()
        let web = QTMemoryWebCookieStore()
        let transport = FakeTransport()
        transport.enqueue("/", data: Data(#"<script>ytcfg.set({"LOGGED_IN":true,"IS_SUBSCRIBER":true,"INNERTUBE_CONTEXT_GL":"DE"})</script>"#.utf8))
        let client = QTInnerTubeClient(transport: transport, retry: .none, scrapesClientConfig: false, sleep: { _ in })
        let controller = QTAuthController(sessionStore: QTSessionStore(store: memory), cookieStore: web, client: client)
        await controller.restore()
        try await controller.importSession(cookies: QTCookieImport.parseNetscape(Self.cookiesTxt))
        #expect(controller.isSignedIn)
        #expect(controller.accountContext?.gl == "DE")
        #expect(try memory.read() != nil)
        #expect(web.cookies.contains { $0.name == "SID" && $0.value == "FAKE-SID" })
    }

    /// Sign-out ends the session at Google with the newest cookies (the jar's rotations win over the Keychain's).
    @MainActor
    @Test func signOutRevokesAtGoogleWithTheNewestCookies() async throws {
        let memory = QTMemorySecureStore()
        let web = QTMemoryWebCookieStore()
        let controller = QTAuthController(sessionStore: QTSessionStore(store: memory), cookieStore: web, client: nil)
        #expect(controller.revokeAtGoogle == nil, "an in-memory jar never reaches Google")
        var revoked: [[QTCookie]] = []
        controller.revokeAtGoogle = { revoked.append($0) }
        await controller.signOut()
        #expect(revoked.isEmpty, "nothing to revoke when signed out")

        try await controller.importSession(cookies: AuthTests.fakeLogin())
        web.simulatePageRotation([QTCookie(name: "__Secure-1PSIDTS", value: "ROTATED", domain: ".youtube.com")])
        await controller.signOut()
        let cookies = try #require(revoked.first)
        #expect(cookies.contains { $0.name == "SID" && $0.value == "FAKE-SID" })
        #expect(cookies.first { $0.name == "__Secure-1PSIDTS" }?.value == "ROTATED")
        #expect(!cookies.contains { $0.name == "VISITOR_INFO1_LIVE" })
        #expect(controller.state == .signedOut)
        #expect(try memory.read() == nil)
    }

    /// DEBUG builds never revoke the shared dev session unless asked (`-qt.auth.revoke YES`).
    @MainActor
    @Test func debugBuildsDontRevokeByDefault() {
        let controller = QTAuthController(sessionStore: QTSessionStore(store: QTMemorySecureStore()),
                                          cookieStore: QTWebKitCookieStore(dataStore: .nonPersistent()), client: nil)
        #if DEBUG
        #expect(controller.revokeAtGoogle == nil)
        #else
        #expect(controller.revokeAtGoogle != nil)
        #endif
    }
}
