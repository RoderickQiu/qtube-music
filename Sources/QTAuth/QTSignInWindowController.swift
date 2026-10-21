import AppKit
import QTCore
import QTInnerTube
import SecurityInterface
import WebKit

/// Google sign-in in a native sheet on the main window (a standalone window when there's no parent), holding a
/// `WKWebView`: accounts.google.com → continue to music.youtube.com. Google's own page carries the sign-in itself; the
/// sheet adds only compact trust cues, the way the system's web sign-in sheets do: an address strip (lock and host;
/// click for the certificate; a warning off Google's sites), one line on what the app keeps, a ? popover on why this
/// isn't the browser, and Cancel. Finishes when music.youtube.com loads with a complete login in the cookie store.
/// The page runs with WebAuthn hidden (`QTSignInPage`), and links that open new windows go to the default browser.
@MainActor
final class QTSignInWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
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

    static let contentSize = NSSize(width: 480, height: 680)
    static let stripHeight: CGFloat = 30
    static let barHeight: CGFloat = 52

    private let webView: WKWebView
    private let cookieStore: any QTWebCookieStore
    private var completion: ((Result<[QTCookie], QTAuthError>) -> Void)?
    private var observations: [NSKeyValueObservation] = []
    private weak var sheetParent: NSWindow?
    private let addressButton = NSButton(title: "", target: nil, action: nil)
    /// DEBUG screenshots: the strip shows this instead of the page's address (the page is a local placeholder).
    private let previewAddress: QTSignInAddress?
    private var certificatePanel: SFCertificatePanel?
    private var helpPopover: NSPopover?

    /// - Parameter previewAddress: DEBUG screenshots only. Loads a local placeholder instead of Google and shows this
    ///   address in the strip; nothing goes to the network.
    init(dataStore: WKWebsiteDataStore, cookieStore: any QTWebCookieStore, hl: String,
         previewAddress: QTSignInAddress? = nil,
         completion: @escaping (Result<[QTCookie], QTAuthError>) -> Void) {
        webView = WKWebView(frame: .zero, configuration: QTSignInPage.configuration(dataStore: dataStore))
        webView.setAccessibilityIdentifier("qt.auth.signIn.webView")
        self.cookieStore = cookieStore
        self.completion = completion
        self.previewAddress = previewAddress

        let size = Self.contentSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("qt.auth.signIn.window")
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 420, height: 540)
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.contentView = makeContent()
        window.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.title, options: [.initial, .new]) { [weak window] view, _ in
                QTMainActorHop.onMainThread { window?.title = view.title ?? "" }
            },
            webView.observe(\.url, options: [.initial, .new]) { [weak self] _, _ in
                QTMainActorHop.onMainThread { self?.updateAddress() }
            },
            webView.observe(\.hasOnlySecureContent, options: [.new]) { [weak self] _, _ in
                QTMainActorHop.onMainThread { self?.updateAddress() }
            },
        ]
        if previewAddress != nil {
            webView.loadHTMLString(Self.placeholderHTML, baseURL: nil)
        } else {
            webView.load(URLRequest(url: Self.signInURL(hl: hl)))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    private func makeContent() -> NSView {
        let content = NSView(frame: NSRect(origin: .zero, size: Self.contentSize))
        let strip = makeStrip()
        let bar = makeBar()
        for v in [strip, webView, bar] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: content.topAnchor),
            strip.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            strip.heightAnchor.constraint(equalToConstant: Self.stripHeight),
            webView.topAnchor.constraint(equalTo: strip.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: Self.barHeight),
        ])
        return content
    }

    /// Top strip, like the address field of the system's web sign-in sheet: the lock and the page's host, centred on
    /// the bar material. Clicking it shows the server's certificate.
    private func makeStrip() -> NSView {
        let strip = NSVisualEffectView()
        strip.material = .titlebar
        strip.blendingMode = .withinWindow
        strip.state = .followsWindowActiveState
        let line = NSBox()
        line.boxType = .separator
        addressButton.isBordered = false
        addressButton.imagePosition = .imageLeading
        addressButton.imageHugsTitle = true
        addressButton.target = self
        addressButton.action = #selector(showCertificate)
        addressButton.setAccessibilityIdentifier("qt.auth.signIn.address")
        for v in [addressButton, line] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            strip.addSubview(v)
        }
        NSLayoutConstraint.activate([
            addressButton.centerXAnchor.constraint(equalTo: strip.centerXAnchor),
            addressButton.centerYAnchor.constraint(equalTo: strip.centerYAnchor),
            addressButton.leadingAnchor.constraint(greaterThanOrEqualTo: strip.leadingAnchor, constant: 12),
            line.leadingAnchor.constraint(equalTo: strip.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: strip.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: strip.bottomAnchor),
        ])
        addressButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return strip
    }

    /// Bottom bar: the help button, one line on what the app keeps, and Cancel (Esc), like the system's own account
    /// sheets.
    private func makeBar() -> NSView {
        let bar = QTSignInBar()
        let line = NSBox()
        line.boxType = .separator
        let help = NSButton(title: "", target: self, action: #selector(showHelp(_:)))
        help.bezelStyle = .helpButton
        help.toolTip = QTLoc.tr("Why not my browser?", table: .live)
        help.setAccessibilityLabel(QTLoc.tr("Why not my browser?", table: .live))
        help.setAccessibilityIdentifier("qt.auth.signIn.help")
        let keeps = NSTextField(wrappingLabelWithString: QTLoc.tr("QTube Music keeps only Google’s sign-in cookies, in your Keychain. Never your password.", table: .live))
        keeps.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        keeps.textColor = .secondaryLabelColor
        keeps.maximumNumberOfLines = 2
        keeps.cell?.truncatesLastVisibleLine = true
        keeps.isSelectable = false
        keeps.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        keeps.setAccessibilityIdentifier("qt.auth.signIn.keeps")
        bar.label = keeps
        let cancel = NSButton(title: QTLoc.tr("Cancel", table: .live), target: self, action: #selector(cancelPressed))
        cancel.bezelStyle = .push
        cancel.controlSize = .large
        cancel.keyEquivalent = "\u{1b}"
        cancel.setAccessibilityIdentifier("qt.auth.signIn.cancel")
        cancel.setContentCompressionResistancePriority(.required, for: .horizontal)
        for v in [line, help, keeps, cancel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(v)
        }
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: bar.topAnchor),
            line.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            help.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 16),
            help.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            keeps.leadingAnchor.constraint(equalTo: help.trailingAnchor, constant: 8),
            keeps.trailingAnchor.constraint(equalTo: cancel.leadingAnchor, constant: -12),
            keeps.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            cancel.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -16),
            cancel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        return bar
    }

    // MARK: Address strip

    private var address: QTSignInAddress {
        previewAddress ?? QTSignInAddress(url: webView.url, hasOnlySecureContent: webView.hasOnlySecureContent)
    }

    private func updateAddress() {
        let address = self.address
        guard let host = address.host else {
            addressButton.isHidden = true
            return
        }
        addressButton.isHidden = false
        let symbol: String
        let text: String
        var color = NSColor.secondaryLabelColor
        switch address {
        case .secure:
            symbol = "lock.fill"
            text = host
            addressButton.toolTip = QTLoc.tr("Show Certificate", table: .live)
        case .notSecure:
            symbol = "lock.slash.fill"
            text = QTLoc.tr("Not Secure — %@", table: .live, host)
            color = .systemRed
            addressButton.toolTip = QTLoc.tr("This page isn’t private. Don’t sign in here.", table: .live)
        case .otherSite:
            symbol = "exclamationmark.triangle.fill"
            text = QTLoc.tr("%@ — not a Google page", table: .live, host)
            addressButton.toolTip = QTLoc.tr("Only sign in here if you expected this page, such as your work’s sign-in.", table: .live)
        case .loading:
            return
        }
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small) + 1)
        var config = NSImage.SymbolConfiguration(pointSize: font.pointSize - 1, weight: .medium)
        if case .otherSite = address {
            config = config.applying(.preferringMulticolor())
        } else {
            config = config.applying(.init(paletteColors: [color]))
        }
        addressButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        addressButton.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: address.isTrusted ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ])
        addressButton.setAccessibilityLabel(text)
    }

    /// The server's certificate chain, as Safari shows it (a sheet on this window). Nothing when there's no TLS.
    @objc private func showCertificate() {
        guard let window, let trust = webView.serverTrust, previewAddress == nil else {
            NSSound.beep()
            return
        }
        let panel = SFCertificatePanel()
        certificatePanel = panel
        panel.beginSheet(for: window, modalDelegate: nil, didEnd: nil, contextInfo: nil, trust: trust, showGroup: true)
    }

    // MARK: Help

    @objc private func showHelp(_ sender: NSButton) {
        if let helpPopover, helpPopover.isShown {
            helpPopover.close()
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = QTSignInHelpController()
        helpPopover = popover
        // Upward, into the window above the bar: `.maxY` is the bottom in the button's flipped coordinates, which
        // hung the popover off the window's lower edge.
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: sender.isFlipped ? .minY : .maxY)
    }

    #if DEBUG
    /// Screenshots: the help popover, opened without a click.
    func showHelpForScreenshot() {
        guard let help = window?.contentView?.firstSubview(identifier: "qt.auth.signIn.help") as? NSButton else { return }
        showHelp(help)
    }
    #endif

    // MARK: Presenting

    /// A sheet on `parent` (user-initiated); a centred window when there's none.
    func present(over parent: NSWindow?, quietly: Bool = false) {
        guard let window else { return }
        if quietly, let parent {
            // Screenshots of a background app: the same window, placed where the sheet goes, shown without becoming
            // key once the page has loaded (Stage Manager pulls a background app's new windows into its strip
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
        updateAddress()
        if pendingQuietShow {
            pendingQuietShow = false
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(700)) // the page settles its layout
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

    // MARK: WKUIDelegate

    /// `window.open` and `target=_blank` links (Google's Learn more, Help, Privacy, Terms) open in the default
    /// browser; the sign-in page never spawns windows of its own.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, QTSignInPage.opensInBrowser(url) {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        finish(.failure(.cancelled))
    }

    private func finish(_ result: Result<[QTCookie], QTAuthError>) {
        guard let completion else { return }
        self.completion = nil
        observations = []
        helpPopover?.close()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
        completion(result)
        if let window {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            if let parent = sheetParent {
                parent.endSheet(window)
            } else {
                window.orderOut(nil)
            }
        }
    }

    /// DEBUG screenshots' page: local, no network, no Google.
    static let placeholderHTML = """
    <!doctype html><meta charset="utf-8"><meta name="color-scheme" content="light dark">
    <style>html,body{height:100%;margin:0}body{display:flex;align-items:center;justify-content:center;
    font:13px -apple-system;color:GrayText}</style><body>Google’s sign-in page appears here.</body>
    """
}

/// The bottom bar keeps its wrapping label's line width in step with the bar (two lines when narrow).
private final class QTSignInBar: NSView {
    weak var label: NSTextField?

    override func layout() {
        super.layout()
        if let label, label.preferredMaxLayoutWidth != label.frame.width {
            label.preferredMaxLayoutWidth = label.frame.width
        }
    }
}

/// The ? popover: why this is a sign-in page in the app and not the browser, and what to do with a passkey.
private final class QTSignInHelpController: NSViewController {
    override func loadView() {
        let width: CGFloat = 300
        func label(_ text: String, bold: Bool = false) -> NSTextField {
            let l = NSTextField(wrappingLabelWithString: text)
            l.font = bold ? .boldSystemFont(ofSize: NSFont.systemFontSize) : .systemFont(ofSize: NSFont.smallSystemFontSize + 1)
            l.isSelectable = false
            l.preferredMaxLayoutWidth = width
            return l
        }
        let stack = NSStackView(views: [
            label(QTLoc.tr("Why not my browser?", table: .live), bold: true),
            label(QTLoc.tr("macOS doesn’t let apps use what you signed in to in your browser, so you sign in to Google here, in a private page that’s deleted afterwards.", table: .live)),
            label(QTLoc.tr("Passkeys and security keys only work in apps Apple approves as web browsers. Use your password with a phone prompt or code, or choose “Try another way”.", table: .live)),
            label(QTLoc.tr("Account with Advanced Protection, or passkeys only? Use Import Session in Settings › Account.", table: .live)),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 16, right: 16)
        stack.setAccessibilityIdentifier("qt.auth.signIn.helpText")
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: width + 32).isActive = true
        stack.frame.size = stack.fittingSize
        view = stack
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Screenshots find the popover's window by this.
        view.window?.identifier = NSUserInterfaceItemIdentifier("qt.auth.signIn.helpPopover")
    }
}

private extension NSView {
    func firstSubview(identifier: String) -> NSView? {
        for v in subviews {
            if v.accessibilityIdentifier() == identifier { return v }
            if let found = v.firstSubview(identifier: identifier) { return found }
        }
        return nil
    }
}
