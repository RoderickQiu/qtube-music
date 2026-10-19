import AppKit
import Foundation
import Observation
import os
import QTCore
import WebKit

/// One Song⇄Video switch of the same track, measured by the web engine: the position the new rendition was asked
/// to start at (the old one's position at the switch) and where it actually started playing.
public struct QTModeSwitchReport: Sendable, Hashable {
    public var videoID: String
    public var from: QTPlaybackMode
    public var to: QTPlaybackMode
    /// Seconds into the track when the switch was asked for.
    public var requested: TimeInterval
    /// Seconds into the new rendition when it started playing.
    public var landed: TimeInterval
    /// Switch request → new rendition playing, in seconds.
    public var latency: TimeInterval
    /// `landed - requested`.
    public var offset: TimeInterval { landed - requested }

    public init(videoID: String, from: QTPlaybackMode, to: QTPlaybackMode, requested: TimeInterval, landed: TimeInterval,
                latency: TimeInterval) {
        self.videoID = videoID
        self.from = from
        self.to = to
        self.requested = requested
        self.landed = landed
        self.latency = latency
    }
}

/// The web engine's music video, shown in the app's own views (M5).
///
/// There is one player page, so there is one video: `present(in:)` moves the engine's `WKWebView` into an app view
/// (the page turns into a bare `<video>` surface — no YouTube UI, transparent page, never takes clicks, focus or
/// VoiceOver) and asks YouTube for a rendition that fits the slot; `withdraw(from:)` returns it to the hidden host
/// window and drops back to 144p, so audio-only listening never decodes more video than it must. Moving the view
/// never interrupts playback (WebKit keeps the page and its media; the engine keeps hidden pages scheduled).
///
/// `hasFrame` says when the page shows a content frame of the requested rendition, so slots keep their artwork up
/// (and crossfade) until the video really is there — after a Song⇄Video switch, between tracks, during ads.
/// Picture in Picture is WebKit's native one (`setPictureInPicture(_:)`); `isPictureInPictureActive` follows the
/// page, including when the user closes the PiP window.
@MainActor
@Observable
public final class QTWebVideoOutput {
    static let log = Logger(subsystem: "com.roderickqiu.qtube", category: "video")

    /// The page shows a decoded content frame of the current item's requested video (not an ad, not loading).
    public private(set) var hasFrame = false
    /// Decoded video size in pixels (zero until a frame exists).
    public private(set) var videoSize: CGSize = .zero
    /// The current item was loaded as its music video.
    public private(set) var isVideoItem = false
    /// The video floats in WebKit's Picture in Picture window.
    public private(set) var isPictureInPictureActive = false

    /// The app view showing the video (nil = the hidden host).
    @ObservationIgnored public private(set) weak var container: NSView?
    @ObservationIgnored weak var engine: QTWebPlaybackEngine?
    /// The rendition asked for while presenting ('small' … 'hd1080'); 'tiny' otherwise.
    @ObservationIgnored private(set) var quality = "tiny"
    @ObservationIgnored private var sentPresentation: (on: Bool, quality: String)?

    init() {}

    /// Whether an app view shows the video right now.
    public var isPresenting: Bool { container != nil }

    // MARK: Hosting

    /// Shows the page's video inside `container` (filling it; keep the container's own backdrop behind it).
    /// Takes the video from any other container. Safe to call repeatedly (layout passes).
    public func present(in container: NSView) {
        let changed = self.container !== container
        self.container = container
        quality = Self.quality(forPixelHeight: container.bounds.height * (container.window?.backingScaleFactor ?? 2))
        if changed { Self.log.debug("present in \(String(describing: type(of: container)), privacy: .public) quality \(self.quality, privacy: .public)") }
        attachIfPossible()
        sendPresentation()
    }

    /// Returns the video to the hidden host if `container` shows it (no-op otherwise).
    public func withdraw(from container: NSView) {
        guard self.container === container else { return }
        self.container = nil
        quality = "tiny"
        Self.log.debug("withdraw")
        if let engine, let webView = engine.webView, let root = engine.hostWindow?.contentView, webView.superview !== root {
            (webView as? QTWebPlaybackView)?.isPresentedInApp = false
            engine.pageWillMoveBetweenWindows()
            // One reparent, straight from window to window: a page that is momentarily without a window
            // interrupts its media.
            root.addSubview(webView)
            webView.frame = root.bounds
            webView.autoresizingMask = [.width, .height]
        }
        sendPresentation()
    }

    /// Native Picture in Picture for the current video. Returns whether the page accepted the request.
    @discardableResult
    public func setPictureInPicture(_ on: Bool) async -> Bool {
        guard let engine else { return false }
        let ok = await engine.command("pip", on)
        Self.log.info("pip(\(on, privacy: .public)) → \(ok, privacy: .public)")
        return ok
    }

    /// 'small' (240p) for the panel's thumbnail up to 'hd1080' for a full-screen Stage.
    public nonisolated static func quality(forPixelHeight height: CGFloat) -> String {
        switch height {
        case ..<200: "small"
        case ..<420: "medium"
        case ..<600: "large"
        case ..<1000: "hd720"
        default: "hd1080"
        }
    }

    // MARK: Engine hooks

    func webViewDidLoad() { attachIfPossible() }

    func pageDidBecomeReady() {
        sentPresentation = nil
        sendPresentation()
    }

    func itemDidChange(isVideo: Bool) {
        isVideoItem = isVideo
        if hasFrame { hasFrame = false }
        if !isVideo, isPictureInPictureActive {
            // The song rendition has nothing to float.
            Task { await setPictureInPicture(false) }
        }
    }

    func update(hasFrame frame: Bool, size: CGSize) {
        let value = frame && isVideoItem
        if hasFrame != value { hasFrame = value }
        if videoSize != size { videoSize = size }
    }

    func update(isPictureInPicture: Bool) {
        if isPictureInPictureActive != isPictureInPicture { isPictureInPictureActive = isPictureInPicture }
    }

    func engineWillTearDown() {
        if let container { withdraw(from: container) }
        hasFrame = false
        isPictureInPictureActive = false
        sentPresentation = nil
    }

    // MARK: Private

    private func attachIfPossible() {
        guard let container, let engine, let webView = engine.webView else { return }
        guard webView.superview !== container else { return }
        engine.pageWillMoveBetweenWindows()
        (webView as? QTWebPlaybackView)?.isPresentedInApp = true
        // Under a full-size-content title bar WebKit would start the page below the toolbar (a black band over
        // the Stage); the video fills the slot edge to edge.
        let adjusts = NSSelectorFromString("_setAutomaticallyAdjustsContentInsets:")
        if webView.responds(to: adjusts) {
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(webView.method(for: adjusts), to: Setter.self)(webView, adjusts, false)
        }
        if #available(macOS 26, *) { webView.obscuredContentInsets = NSEdgeInsetsZero }
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView, positioned: .below, relativeTo: nil)
    }

    private func sendPresentation() {
        let wanted = (on: isPresenting, quality: isPresenting ? quality : "tiny")
        if let sent = sentPresentation, sent == wanted { return }
        sentPresentation = wanted
        guard let engine else { return }
        Task { @MainActor [weak self] in
            let ok = await engine.command("present", wanted.on, wanted.quality)
            // Not ready yet: `pageDidBecomeReady` sends it again (and the next page boots with it).
            if !ok, let self, let sent = self.sentPresentation, sent == wanted { self.sentPresentation = nil }
        }
    }
}

/// The player's web view. While an app view hosts it (video slot) it never takes focus, clicks, keyboard view
/// loop or VoiceOver: the page is a picture, not a browser.
final class QTWebPlaybackView: WKWebView {
    var isPresentedInApp = false

    override var acceptsFirstResponder: Bool { isPresentedInApp ? false : super.acceptsFirstResponder }
    override var canBecomeKeyView: Bool { isPresentedInApp ? false : super.canBecomeKeyView }
    override func hitTest(_ point: NSPoint) -> NSView? { isPresentedInApp ? nil : super.hitTest(point) }
    override func accessibilityChildren() -> [Any]? { isPresentedInApp ? [] : super.accessibilityChildren() }
    override func isAccessibilityElement() -> Bool { isPresentedInApp ? false : super.isAccessibilityElement() }
    override func accessibilityRole() -> NSAccessibility.Role? { isPresentedInApp ? .unknown : super.accessibilityRole() }
    override func menu(for event: NSEvent) -> NSMenu? { isPresentedInApp ? nil : super.menu(for: event) }
    override func scrollWheel(with event: NSEvent) {
        if isPresentedInApp { nextResponder?.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }
}
