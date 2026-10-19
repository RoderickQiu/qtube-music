import Foundation
import WebKit

/// A WebKit cookie jar the auth controller keeps in step with the Keychain session. Abstracted for tests.
///
/// The session never lives in a *persistent* WebKit store: WebKit writes those to
/// `~/Library/HTTPStorages/<bundle id>.binarycookies` in plain text. The app's jar is `QTWebKitCookieStore.session`,
/// a non-persistent store seeded from the Keychain at launch; Google's cookie rotations in it are folded back into
/// the Keychain through `onChange`.
@MainActor
public protocol QTWebCookieStore: AnyObject {
    /// True for a jar WebKit saves to disk. The auth controller never writes session cookies into one.
    var isPersistent: Bool { get }
    func allCookies() async -> [QTCookie]
    func set(_ cookies: [QTCookie]) async
    /// Deletes every Google / YouTube cookie.
    func removeGoogleCookies() async
    /// Called after the jar's cookies changed (WebKit's `WKHTTPCookieStoreObserver`). One handler.
    var onChange: (@MainActor () -> Void)? { get set }
}

/// A `WKWebsiteDataStore`'s cookie jar.
@MainActor
public final class QTWebKitCookieStore: QTWebCookieStore {
    /// The process's signed-in jar: a **non-persistent** store (memory only, never on disk), shared by the web
    /// playback engine so signed-in playback uses the user's session. Seeded from the Keychain by
    /// `QTAuthController.restore()` / sign-in, emptied by sign-out.
    public static let session = QTWebKitCookieStore(dataStore: .nonPersistent())

    public let dataStore: WKWebsiteDataStore
    public var onChange: (@MainActor () -> Void)? {
        didSet { installObserverIfNeeded() }
    }
    private var observer: QTCookieStoreObserver?

    public init(dataStore: WKWebsiteDataStore) {
        self.dataStore = dataStore
    }

    public var isPersistent: Bool { dataStore.isPersistent }

    public func allCookies() async -> [QTCookie] {
        await dataStore.httpCookieStore.allCookies().map(QTCookie.init)
    }

    public func set(_ cookies: [QTCookie]) async {
        let store = dataStore.httpCookieStore
        for cookie in cookies {
            if let http = cookie.httpCookie { await store.setCookie(http) }
        }
    }

    public func removeGoogleCookies() async {
        let store = dataStore.httpCookieStore
        for cookie in await store.allCookies() where QTCookie(cookie).isGoogleOrYouTube {
            await store.deleteCookie(cookie)
        }
        // Also drop cached site data (local storage, service workers) for the Google/YouTube sites.
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await dataStore.dataRecords(ofTypes: types)
        let google = records.filter { r in
            r.displayName.contains("youtube.com") || r.displayName.contains("google.com")
        }
        if !google.isEmpty { await dataStore.removeData(ofTypes: types, for: google) }
    }

    private func installObserverIfNeeded() {
        guard observer == nil, onChange != nil else { return }
        let observer = QTCookieStoreObserver { [weak self] in self?.onChange?() }
        self.observer = observer
        dataStore.httpCookieStore.add(observer)
    }
}

/// `WKHTTPCookieStoreObserver` → closure (WebKit holds observers weakly; the store keeps this one).
@MainActor
private final class QTCookieStoreObserver: NSObject, WKHTTPCookieStoreObserver {
    let handler: @MainActor () -> Void

    init(_ handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        MainActor.assumeIsolated { handler() }
    }
}

/// In-memory cookie jar (tests). `isPersistent` lets tests stand in for WebKit's on-disk default store.
@MainActor
public final class QTMemoryWebCookieStore: QTWebCookieStore {
    public private(set) var cookies: [QTCookie]
    public let isPersistent: Bool
    public var onChange: (@MainActor () -> Void)?

    public init(cookies: [QTCookie] = [], isPersistent: Bool = false) {
        self.cookies = cookies
        self.isPersistent = isPersistent
    }

    public func allCookies() async -> [QTCookie] { cookies }

    public func set(_ new: [QTCookie]) async {
        for c in new {
            cookies.removeAll { $0.name == c.name && $0.bareDomain == c.bareDomain && $0.path == c.path }
            cookies.append(c)
        }
        if !new.isEmpty { onChange?() }
    }

    public func removeGoogleCookies() async {
        cookies.removeAll(where: \.isGoogleOrYouTube)
        onChange?()
    }

    /// Tests: the page rotated a cookie (as Google's `RotateCookies` does in the player page).
    public func simulatePageRotation(_ rotated: [QTCookie]) {
        for c in rotated {
            cookies.removeAll { $0.name == c.name && $0.bareDomain == c.bareDomain && $0.path == c.path }
            cookies.append(c)
        }
        onChange?()
    }
}

/// The persistent WebKit data earlier builds left behind. Builds before the session fix signed in through
/// `WKWebsiteDataStore.default()` and re-seeded it every launch, so WebKit saved the Google session in plain text
/// (`~/Library/HTTPStorages/<bundle id>.binarycookies`, mode 0644). The app no longer uses a persistent WebKit
/// store at all, so all of it is deleted at launch — the files only, without loading the store into WebKit. Every
/// launch, not once: an older build of the same bundle id (a dev variant) would otherwise write it again unseen.
public enum QTLegacyWebStorage {
    /// Files and folders WebKit / CFNetwork keep for `bundleID`'s persistent data store.
    public static func paths(bundleID: String, library: URL) -> [URL] {
        let storages = library.appending(path: "HTTPStorages", directoryHint: .isDirectory)
        return [
            storages.appending(path: "\(bundleID).binarycookies"),
            storages.appending(path: "\(bundleID)", directoryHint: .isDirectory),
            library.appending(path: "WebKit", directoryHint: .isDirectory).appending(path: bundleID, directoryHint: .isDirectory),
            library.appending(path: "Caches/\(bundleID)/WebKit", directoryHint: .isDirectory),
        ]
    }

    /// Deletes this app's persistent WebKit data. Only QTube's own bundle ids (`com.roderickqiu.qtube*`).
    /// - Returns: the paths that existed and were removed.
    @discardableResult
    public static func purge(bundleID: String? = Bundle.main.bundleIdentifier,
                             library: URL? = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first,
                             fileManager: FileManager = .default) -> [URL] {
        guard let bundleID, bundleID.hasPrefix("com.roderickqiu.qtube"), let library else { return [] }
        var removed: [URL] = []
        for url in paths(bundleID: bundleID, library: library) where fileManager.fileExists(atPath: url.path) {
            if (try? fileManager.removeItem(at: url)) != nil { removed.append(url) }
        }
        return removed
    }
}
