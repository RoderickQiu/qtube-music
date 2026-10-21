import Foundation
import QTInnerTube
import WebKit

// Brand-account switching for the web session. Kaset (MIT, github.com/sozercan/kaset — docs/adr/0023, WebKitManager
// `switchSessionIdentity`) found that YouTube records plays for the identity the *player page* is signed in as
// (`ytcfg.DATASYNC_ID`), not for the API's `onBehalfOfUser`. So a switch loads YouTube's own account-switch page
// (`accounts_list` → `accountSigninToken.signinUrl`) in the session jar and only counts once the page's
// `DATASYNC_ID` names the new identity. Re-implemented.

/// Moves the web session (the player page's cookies) to another identity of the same Google account.
@MainActor
public protocol QTSessionIdentitySwitching: AnyObject {
    /// Loads `signinURL` in `dataStore` and returns once a page there reports `brandId` (nil = the Google account
    /// itself) as its identity. Throws when it can't be confirmed.
    func switchIdentity(to signinURL: URL, brandId: String?, dataStore: WKWebsiteDataStore?) async throws
}

public enum QTIdentitySwitchError: Error, Sendable, Equatable {
    /// Not YouTube's `https://www.youtube.com/signin` page, or no switch link.
    case invalidLink
    /// No WebKit session jar to switch (tests, or signed out).
    case noWebSession
    case navigationFailed
    case timedOut
    /// The page loaded but still names another identity.
    case notApplied
}

extension QTIdentitySwitchError {
    /// The page couldn't be reached or took too long (offline, a slow network): worth another try later. The others
    /// mean the link or YouTube refused the identity.
    public var isTransient: Bool { self == .navigationFailed || self == .timedOut }
}

/// The WebKit implementation: a hidden, muted page in the session jar, closed again after the check. Switches run one
/// at a time (two pages moving one jar to different identities would race), and each has its own page and load
/// state, so an overlapping call waits its turn instead of taking over the first one's.
@MainActor
public final class QTWebIdentitySwitcher: QTSessionIdentitySwitching {
    private var last: Task<Void, Never>?

    public init() {}

    public func switchIdentity(to signinURL: URL, brandId: String?, dataStore: WKWebsiteDataStore?) async throws {
        guard QTWriteParser.isAllowedSigninURL(signinURL) else { throw QTIdentitySwitchError.invalidLink }
        guard let dataStore, !dataStore.isPersistent else { throw QTIdentitySwitchError.noWebSession }
        let previous = last
        let mine = Task { @MainActor in
            await previous?.value
            try await Self.perform(signinURL, brandId: brandId, dataStore: dataStore)
        }
        last = Task { _ = try? await mine.value }
        try await mine.value
    }

    private static func perform(_ signinURL: URL, brandId: String?, dataStore: WKWebsiteDataStore) async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        page.customUserAgent = QTInnerTubeConfiguration().userAgent
        let load = PageLoad()
        page.navigationDelegate = load
        defer {
            page.navigationDelegate = nil
            page.stopLoading()
        }
        try await load.run(URLRequest(url: signinURL), in: page, timeout: .seconds(20))
        // `ytcfg` may be set a moment after the load finishes.
        for attempt in 0..<6 {
            let value = try? await page.evaluateJavaScript(dataSyncScript) as? String
            if let value, QTWriteParser.dataSyncId(value, matches: brandId) { return }
            if attempt < 5 { try await Task.sleep(for: .milliseconds(400)) }
        }
        throw QTIdentitySwitchError.notApplied
    }

    static let dataSyncScript = """
    (function () {
      try {
        if (window.ytcfg && typeof window.ytcfg.get === 'function') { return window.ytcfg.get('DATASYNC_ID') || ''; }
        if (window.ytcfg && window.ytcfg.data_) { return window.ytcfg.data_['DATASYNC_ID'] || ''; }
      } catch (e) {}
      return '';
    })();
    """

    /// One page load: finishes once, on the first of finish / failure / timeout.
    @MainActor
    private final class PageLoad: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, any Error>?
        private var timeout: Task<Void, Never>?

        func run(_ request: URLRequest, in page: WKWebView, timeout limit: Duration) async throws {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                continuation = c
                timeout = Task { [weak self] in
                    try? await Task.sleep(for: limit)
                    guard !Task.isCancelled else { return }
                    self?.finish(.failure(QTIdentitySwitchError.timedOut))
                }
                page.load(request)
            }
        }

        private func finish(_ result: Result<Void, any Error>) {
            timeout?.cancel()
            timeout = nil
            let c = continuation
            continuation = nil
            c?.resume(with: result)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finish(.success(()))
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            finish(.failure(QTIdentitySwitchError.navigationFailed))
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: any Error) {
            finish(.failure(QTIdentitySwitchError.navigationFailed))
        }
    }
}
