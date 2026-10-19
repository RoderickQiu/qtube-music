import AppKit
import QTCore
import QTInnerTube
import WebKit

/// Google sign-in in a native sheet on the main window (a standalone window when there's no parent), holding a
/// `WKWebView`: accounts.google.com → continue to music.youtube.com. Google's own page carries all the copy; the
/// sheet adds only Cancel. Finishes when music.youtube.com loads with a complete login in the cookie store.
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

    static let contentSize = NSSize(width: 480, height: 640)
    static let barHeight: CGFloat = 52

    private let webView: WKWebView
    private let cookieStore: any QTWebCookieStore
    private var completion: ((Result<[QTCookie], QTAuthError>) -> Void)?
    private var titleObservation: NSKeyValueObservation?
    private weak var sheetParent: NSWindow?

    init(dataStore: WKWebsiteDataStore, cookieStore: any QTWebCookieStore, hl: String,
         completion: @escaping (Result<[QTCookie], QTAuthError>) -> Void) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.mediaTypesRequiringUserActionForPlayback = .all
        let size = Self.contentSize
        webView = WKWebView(frame: NSRect(x: 0, y: Self.barHeight, width: size.width, height: size.height - Self.barHeight),
                            configuration: config)
        // Google refuses embedded browsers that don't look like Safari.
        webView.customUserAgent = QTInnerTubeConfiguration.defaultUserAgent
        webView.autoresizingMask = [.width, .height]
        webView.setAccessibilityIdentifier("qt.auth.signIn.webView")
        self.cookieStore = cookieStore
        self.completion = completion

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("qt.auth.signIn.window")
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 400, height: 520)
        window.tabbingMode = .disallowed
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.addSubview(webView)
        super.init(window: window)
        content.addSubview(makeBar(width: size.width))
        window.contentView = content
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

    /// Bottom bar: a separator and Cancel (Esc), like the system's own account sheets.
    private func makeBar(width: CGFloat) -> NSView {
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: width, height: Self.barHeight))
        bar.autoresizingMask = [.width]
        let line = NSBox(frame: NSRect(x: 0, y: Self.barHeight - 1, width: width, height: 1))
        line.boxType = .separator
        line.autoresizingMask = [.width]
        bar.addSubview(line)
        let cancel = NSButton(title: QTLoc.tr("Cancel", table: .live), target: self, action: #selector(cancelPressed))
        cancel.bezelStyle = .push
        cancel.controlSize = .large
        cancel.keyEquivalent = "\u{1b}"
        cancel.setAccessibilityIdentifier("qt.auth.signIn.cancel")
        cancel.sizeToFit()
        cancel.frame.origin = NSPoint(x: width - cancel.frame.width - 16, y: (Self.barHeight - cancel.frame.height) / 2)
        cancel.autoresizingMask = [.minXMargin]
        bar.addSubview(cancel)
        return bar
    }

    /// A sheet on `parent` (user-initiated); a centred window when there's none.
    func present(over parent: NSWindow?, quietly: Bool = false) {
        guard let window else { return }
        if quietly, let parent {
            // Screenshots of a background app: the same window, placed where the sheet goes, shown without becoming
            // key once Google's page has loaded (Stage Manager pulls a background app's new windows into its strip
            // after a moment, so the capture has to follow the first frame closely).
            let f = parent.frame
            window.setFrameOrigin(NSPoint(x: f.midX - window.frame.width / 2, y: f.maxY - window.frame.height - 60))
            pendingQuietShow = true
            return
        }
        if let parent {
            if parent.attachedSheet !== window {
                sheetParent = parent
                parent.beginSheet(window)
            }
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }

    override func close() {
        finish(.failure(.cancelled))
    }

    @objc private func cancelPressed() {
        finish(.failure(.cancelled))
    }

    // MARK: WKNavigationDelegate

    /// Posted when a quietly presented window appears (DEBUG screenshots wait for it).
    static let didShowQuietly = Notification.Name("QTSignInWindowDidShowQuietly")
    private var pendingQuietShow = false

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if pendingQuietShow {
            pendingQuietShow = false
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(700)) // Google's page settles its layout
                self?.window?.orderFront(nil)
                NotificationCenter.default.post(name: Self.didShowQuietly, object: nil)
            }
        }
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
        if let window {
            if let parent = sheetParent {
                parent.endSheet(window)
            } else {
                window.orderOut(nil)
            }
        }
    }
}
