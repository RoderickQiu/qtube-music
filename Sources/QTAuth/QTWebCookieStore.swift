import Foundation
import WebKit

/// The WebKit cookie jar the sign-in window and the web playback engine share. Abstracted for tests.
@MainActor
public protocol QTWebCookieStore: AnyObject {
    func allCookies() async -> [QTCookie]
    func set(_ cookies: [QTCookie]) async
    /// Deletes every Google / YouTube cookie.
    func removeGoogleCookies() async
}

/// `WKWebsiteDataStore.default()` — persistent, shared by every WKWebView in the app (sign-in and playback), so a
/// login in one is a login in the other.
@MainActor
public final class QTWebKitCookieStore: QTWebCookieStore {
    public let dataStore: WKWebsiteDataStore

    public init(dataStore: WKWebsiteDataStore = .default()) {
        self.dataStore = dataStore
    }

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
}

/// In-memory cookie jar (tests).
@MainActor
public final class QTMemoryWebCookieStore: QTWebCookieStore {
    public private(set) var cookies: [QTCookie]

    public init(cookies: [QTCookie] = []) { self.cookies = cookies }

    public func allCookies() async -> [QTCookie] { cookies }

    public func set(_ new: [QTCookie]) async {
        for c in new {
            cookies.removeAll { $0.name == c.name && $0.bareDomain == c.bareDomain && $0.path == c.path }
            cookies.append(c)
        }
    }

    public func removeGoogleCookies() async {
        cookies.removeAll(where: \.isGoogleOrYouTube)
    }
}
