import Foundation
import QTInnerTube
import WebKit

/// The sign-in window's page rules, apart from the window so they're testable offline: the WebAuthn-hiding script,
/// what the address strip shows, which links leave for the browser, and the user agent.
public enum QTSignInPage {
    // MARK: WebAuthn

    /// Hides WebAuthn from Google's sign-in pages (Kaset ADR-0033). A `WKWebView` without Apple's managed
    /// `com.apple.developer.web-browser.public-key-credential` entitlement exposes `PublicKeyCredential`, but macOS
    /// rejects every passkey / security-key ceremony at once with `NotAllowedError` and no UI. Google reads that as a
    /// failed phone check ("check that Bluetooth is on") and the sign-in dead-ends. Without the API Google offers what
    /// works here: password, then a phone prompt, SMS or an authenticator code ("Try another way").
    ///
    /// Two layers, each guarded so a WebKit change can't break the page itself: `PublicKeyCredential` is undefined
    /// (Google feature-detects it before offering passkeys), and a `navigator.credentials.get/create` that still asks
    /// for a `publicKey` credential is refused with the same `NotAllowedError` the system would give.
    public static let hideWebAuthnScript = """
    (function () {
        "use strict";
        try {
            delete window.PublicKeyCredential;
            Object.defineProperty(window, "PublicKeyCredential", { value: undefined, writable: false, configurable: false });
        } catch (e) {}
        try {
            var credentials = window.navigator && window.navigator.credentials;
            if (!credentials) { return; }
            var proto = Object.getPrototypeOf(credentials);
            var wrap = function (original) {
                if (typeof original !== "function") { return original; }
                return function (options) {
                    if (options && options.publicKey) {
                        return Promise.reject(new DOMException("Passkeys aren't available in this app.", "NotAllowedError"));
                    }
                    return original.apply(this, arguments);
                };
            };
            proto.get = wrap(proto.get);
            proto.create = wrap(proto.create);
        } catch (e) {}
    })();
    """

    /// The script as the sign-in configuration installs it: at document start, before Google's capability check,
    /// and in every frame (parts of the flow run in iframes). Only the sign-in window gets it; playback never does.
    @MainActor
    public static func hideWebAuthnUserScript() -> WKUserScript {
        WKUserScript(source: hideWebAuthnScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    // MARK: Configuration

    /// The sign-in window's web view configuration: the given (throwaway, non-persistent) store, WebAuthn hidden,
    /// Safari's user agent with the installed Safari's version, no autoplay.
    @MainActor
    public static func configuration(dataStore: WKWebsiteDataStore,
                                     safariVersion: String = QTSafariUserAgent.current) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.mediaTypesRequiringUserActionForPlayback = .all
        // Google refuses embedded browsers that don't look like Safari. WebKit puts its own platform part in front.
        config.applicationNameForUserAgent = QTSafariUserAgent.applicationName(version: safariVersion)
        config.userContentController.addUserScript(hideWebAuthnUserScript())
        return config
    }

    // MARK: Links

    /// Links that open a new window (Google's "Learn more", Help, Privacy, Terms) go to the default browser; only
    /// web addresses — never `javascript:`, `file:` or app schemes.
    public static func opensInBrowser(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased(), url?.host?.isEmpty == false else { return false }
        return scheme == "https" || scheme == "http"
    }
}

/// What the sign-in window's address strip shows for the page it's on.
public enum QTSignInAddress: Equatable, Sendable {
    /// No page yet (or `about:blank`).
    case loading
    /// HTTPS, only secure content, a Google or YouTube host: the lock.
    case secure(host: String)
    /// Plain HTTP or mixed content.
    case notSecure(host: String)
    /// HTTPS, but not Google's (a work account's own sign-in page, or something that shouldn't be there).
    case otherSite(host: String)

    public init(url: URL?, hasOnlySecureContent: Bool) {
        guard let url, let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else {
            self = .loading
            return
        }
        if url.scheme?.lowercased() != "https" || !hasOnlySecureContent {
            self = .notSecure(host: host)
        } else if Self.isGoogle(host: host) {
            self = .secure(host: host)
        } else {
            self = .otherSite(host: host)
        }
    }

    /// `google.com`, `youtube.com` and their subdomains — nothing that merely ends in those letters.
    public static func isGoogle(host: String) -> Bool {
        var h = host.lowercased()
        if h.hasSuffix(".") { h.removeLast() }
        return ["google.com", "youtube.com"].contains { h == $0 || h.hasSuffix("." + $0) }
    }

    public var host: String? {
        switch self {
        case .loading: nil
        case .secure(let h), .notSecure(let h), .otherSite(let h): h
        }
    }

    public var isTrusted: Bool {
        if case .secure = self { return true }
        return false
    }
}
