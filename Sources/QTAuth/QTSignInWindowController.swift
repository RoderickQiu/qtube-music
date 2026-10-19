import AppKit
import QTInnerTube
import WebKit

/// Google sign-in in a plain, native window holding a `WKWebView`: accounts.google.com → continue to
/// music.youtube.com. The window title is the page's own title (Google localizes it), so the app adds no copy.
/// Finishes when music.youtube.com loads with a complete login in the shared cookie store.
@MainActor
final class QTSignInWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate {
    /// Google's own sign-in flow for YouTube Music (the same entry point the web client uses).
    nonisolated static func signInURL(hl: String) -> URL {
        var next = URLComponents(string: "https://www.youtube.com/signin")!
        next.queryItems = [
            URLQueryItem(name: "action_handle_signin", value: "true"),
            URLQueryItem(name: "app", value: "desktop"),
            URLQueryItem(name: "next", value: "https://music.youtube.com/"),
        ]
        var c = URLComponents(string: "https://accounts.google.com/ServiceLogin")!
        c.queryItems = [
            URLQueryItem(name: "service", value: "youtube"),
            URLQueryItem(name: "passive", value: "true"),
            URLQueryItem(name: "continue", value: next.url!.absoluteString),
            URLQueryItem(name: "hl", value: hl),
        ]
        return c.url!
    }

    private let webView: WKWebView
    private let cookieStore: any QTWebCookieStore
    private var completion: ((Result<[QTCookie], QTAuthError>) -> Void)?
    private var titleObservation: NSKeyValueObservation?

    init(dataStore: WKWebsiteDataStore, cookieStore: any QTWebCookieStore, hl: String,
         completion: @escaping (Result<[QTCookie], QTAuthError>) -> Void) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.mediaTypesRequiringUserActionForPlayback = .all
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: config)
        // Google refuses embedded browsers that don't look like Safari.
        webView.customUserAgent = QTInnerTubeConfiguration.defaultUserAgent
        webView.setAccessibilityIdentifier("qt.auth.signIn.webView")
        self.cookieStore = cookieStore
        self.completion = completion

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("qt.auth.signIn.window")
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 400, height: 520)
        window.contentView = webView
        window.titlebarAppearsTransparent = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        webView.navigationDelegate = self
        titleObservation = webView.observe(\.title, options: [.initial, .new]) { [weak window] view, _ in
            MainActor.assumeIsolated {
                window?.title = view.title ?? ""
            }
        }
        webView.load(URLRequest(url: Self.signInURL(hl: hl)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows the window centred over the app's key window (user-initiated, so it may become key).
    func present(over parent: NSWindow?) {
        guard let window else { return }
        if let parent {
            let f = parent.frame
            window.setFrameOrigin(NSPoint(x: f.midX - window.frame.width / 2, y: f.midY - window.frame.height / 2))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let host = webView.url?.host, host == "music.youtube.com" else { return }
        Task { await checkForLogin() }
    }

    private func checkForLogin() async {
        let cookies = await cookieStore.allCookies()
        let session = QTAuthSession(cookies: QTAuthSession.filtered(cookies))
        guard session.isComplete else { return }
        finish(.success(session.cookies))
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        finish(.failure(.cancelled))
    }

    private func finish(_ result: Result<[QTCookie], QTAuthError>) {
        guard let completion else { return }
        self.completion = nil
        titleObservation = nil
        webView.navigationDelegate = nil
        webView.stopLoading()
        completion(result)
        if case .success = result { window?.close() }
    }
}
