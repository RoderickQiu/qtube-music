import Foundation
import WebKit

/// Ends a session at Google, not just in the app: loads `accounts.google.com/Logout` with the session's cookies in a
/// throwaway non-persistent store, as a browser's Sign out does, so the session leaves the account's device list
/// (myaccount.google.com/device-activity) instead of lingering there. Best effort and bounded: the app's own
/// sign-out never waits for it, and the store is dropped afterwards.
@MainActor
final class QTGoogleSignOut: NSObject, WKNavigationDelegate {
    static let logoutURL = URL(string: "https://accounts.google.com/Logout")!
    /// Running sign-outs (each keeps itself alive until it finishes).
    private static var running: [ObjectIdentifier: QTGoogleSignOut] = [:]

    private var webView: WKWebView?
    private var finished: CheckedContinuation<Void, Never>?

    /// Starts a sign-out at Google for `cookies` (the session's allow-listed auth cookies).
    static func revoke(_ cookies: [QTCookie], timeout: Duration = .seconds(15)) {
        guard !cookies.isEmpty else { return }
        let job = QTGoogleSignOut()
        running[ObjectIdentifier(job)] = job
        Task { @MainActor in
            await job.run(cookies: cookies, timeout: timeout)
            running[ObjectIdentifier(job)] = nil
        }
    }

    private func run(cookies: [QTCookie], timeout: Duration) async {
        let store = WKWebsiteDataStore.nonPersistent()
        for cookie in cookies {
            if let http = cookie.httpCookie { await store.httpCookieStore.setCookie(http) }
        }
        let view = WKWebView(frame: .zero, configuration: QTSignInPage.configuration(dataStore: store))
        view.navigationDelegate = self
        webView = view
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            finished = continuation
            view.load(URLRequest(url: Self.logoutURL))
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finish()
            }
        }
        view.stopLoading()
        view.navigationDelegate = nil
        webView = nil
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    private func finish() {
        finished?.resume()
        finished = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Google's logout page then signs the session out of its other domains (youtube.com) from script; give it a
        // moment before the store goes.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.finish()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finish()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finish()
    }
}
