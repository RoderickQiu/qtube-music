import Foundation
import QTInnerTube

/// A browser cookie, Codable for the Keychain. Platform-neutral mirror of `HTTPCookie`.
public struct QTCookie: Codable, Sendable, Hashable {
    public var name: String
    public var value: String
    /// Cookie domain as set (".youtube.com", "music.youtube.com").
    public var domain: String
    public var path: String
    public var expires: Date?
    public var isSecure: Bool
    public var isHTTPOnly: Bool
    public var sameSite: String?

    public init(name: String, value: String, domain: String, path: String = "/", expires: Date? = nil,
                isSecure: Bool = true, isHTTPOnly: Bool = false, sameSite: String? = nil) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expires = expires
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
        self.sameSite = sameSite
    }

    public init(_ cookie: HTTPCookie) {
        self.init(name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path,
                  expires: cookie.expiresDate, isSecure: cookie.isSecure, isHTTPOnly: cookie.isHTTPOnly,
                  sameSite: cookie.sameSitePolicy?.rawValue)
    }

    public var httpCookie: HTTPCookie? {
        var props: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: domain, .path: path.isEmpty ? "/" : path,
        ]
        if let expires { props[.expires] = expires }
        if isSecure { props[.secure] = "TRUE" }
        if isHTTPOnly { props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let sameSite { props[.sameSitePolicy] = sameSite }
        return HTTPCookie(properties: props)
    }

    /// Normalised domain without the leading dot.
    var bareDomain: String { domain.hasPrefix(".") ? String(domain.dropFirst()) : domain }

    /// Whether a request to `host` would carry this cookie.
    public func matches(host: String) -> Bool {
        let d = bareDomain.lowercased()
        let h = host.lowercased()
        return h == d || h.hasSuffix("." + d)
    }

    public func isExpired(at date: Date = Date()) -> Bool {
        expires.map { $0 <= date } ?? false
    }

    /// Google / YouTube session cookie (the only kind the app keeps).
    public var isGoogleOrYouTube: Bool {
        matches(host: "youtube.com") || matches(host: "music.youtube.com") || matches(host: "www.youtube.com")
            || matches(host: "google.com") || matches(host: "accounts.google.com")
            || bareDomain == "youtube.com" || bareDomain == "google.com"
    }
}

/// The signed-in session as stored in the Keychain.
public struct QTAuthSession: Codable, Sendable, Hashable {
    public var cookies: [QTCookie]
    /// `X-Goog-AuthUser` index of the account (multi-login browsers).
    public var authUser: Int
    /// Brand account / channel to act as (`onBehalfOfUser`), nil = the Google account itself.
    public var brandAccountId: String?
    public var account: QTAccountInfo?
    public var savedAt: Date

    public init(cookies: [QTCookie], authUser: Int = 0, brandAccountId: String? = nil, account: QTAccountInfo? = nil,
                savedAt: Date = Date()) {
        self.cookies = cookies
        self.authUser = authUser
        self.brandAccountId = brandAccountId
        self.account = account
        self.savedAt = savedAt
    }

    /// Cookie names that make up a Google/YouTube login (HANDOFF §8). Anything else is not stored.
    public static let authCookieNames: Set<String> = [
        "SAPISID", "__Secure-1PAPISID", "__Secure-3PAPISID", "APISID", "SID", "HSID", "SSID",
        "__Secure-1PSID", "__Secure-3PSID", "__Secure-1PSIDTS", "__Secure-3PSIDTS", "__Secure-1PSIDCC",
        "__Secure-3PSIDCC", "SIDCC", "LOGIN_INFO", "PREF",
    ]

    /// Keeps only Google/YouTube auth cookies, newest value per (name, domain, path), unexpired.
    public static func filtered(_ cookies: [QTCookie], now: Date = Date()) -> [QTCookie] {
        var byKey: [String: QTCookie] = [:]
        for c in cookies where authCookieNames.contains(c.name) && c.isGoogleOrYouTube && !c.isExpired(at: now) {
            byKey["\(c.name)|\(c.bareDomain.lowercased())|\(c.path)"] = c
        }
        return byKey.values.sorted { ($0.bareDomain, $0.name) < ($1.bareDomain, $1.name) }
    }

    /// Cookies sent to music.youtube.com.
    public var youTubeCookies: [QTCookie] {
        cookies.filter { $0.matches(host: "music.youtube.com") }
    }

    /// The SAPISID used for SAPISIDHASH: `SAPISID`, falling back to the `__Secure-3PAPISID` that carries the same
    /// value in newer Google sessions.
    public var sapisid: String? {
        let yt = youTubeCookies
        for name in ["SAPISID", "__Secure-3PAPISID", "__Secure-1PAPISID"] {
            if let c = yt.first(where: { $0.name == name }), !c.value.isEmpty { return c.value }
        }
        return nil
    }

    /// Whether this looks like a usable login (has SAPISID and a session id cookie).
    public var isComplete: Bool {
        sapisid != nil && youTubeCookies.contains { ["SID", "__Secure-1PSID", "__Secure-3PSID"].contains($0.name) }
    }

    public func credentials(now: Date = Date()) -> QTInnerTubeCredentials? {
        guard let sapisid else { return nil }
        let header = youTubeCookies.filter { !$0.isExpired(at: now) }
            .map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        return QTInnerTubeCredentials(cookieHeader: header, sapisid: sapisid, authUser: authUser,
                                      onBehalfOfUser: brandAccountId)
    }

    /// Merges rotated cookies (Set-Cookie from responses, WebKit changes) into the session.
    public func merging(_ updates: [QTCookie], now: Date = Date()) -> QTAuthSession {
        var copy = self
        copy.cookies = Self.filtered(cookies + updates, now: now)
        return copy
    }
}

public enum QTAuthError: Error, Sendable, Equatable {
    /// The cookies don't contain a SAPISID/SID login.
    case incompleteSession
    /// Keychain read/write failed (OSStatus).
    case keychain(status: Int32)
    case encoding
    /// The sign-in window was closed before finishing.
    case cancelled
}
