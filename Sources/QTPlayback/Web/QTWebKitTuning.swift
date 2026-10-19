import Foundation
import ObjectiveC
import WebKit

/// The few WebKit internals `QTWebPlaybackEngine` relies on, in one place, each guarded with `responds(to:)`
/// so a WebKit change degrades to "feature not applied" instead of a crash.
///
/// Why media runs in the WebContent process: when the GPU process plays a page's media it registers a
/// MediaRemote Now Playing client *on behalf of the host app* (`com.apple.WebKit.GPU/<bundle id>`), which shows
/// up as a second Now Playing entry next to the app's own (Kaset bug #457). `WKPreferences` has no switch for
/// that, and `muted` media (WebKit's only eligibility gate on macOS) would be silent. The WebContent process
/// is sandboxed away from MediaRemote, so with `UseGPUProcessForMediaEnabled` off nothing but
/// `QTNowPlayingController` ever reaches the system. Verified on macOS 27 with the system's active player path
/// (see `Sources/QTPlaybackLab`).
@MainActor
enum QTWebKitTuning {
    /// Feature key of WebKit's internal "GPU Process: Media" setting.
    static let gpuProcessForMediaFeature = "UseGPUProcessForMediaEnabled"

    /// Turns off GPU-process media for web views made with these preferences. Returns false if the feature
    /// isn't found (WebKit changed): playback still works, but WebKit may then publish its own Now Playing.
    @discardableResult
    static func runMediaInWebContentProcess(_ preferences: WKPreferences) -> Bool {
        setFeature(gpuProcessForMediaFeature, enabled: false, on: preferences)
    }

    @discardableResult
    static func setFeature(_ key: String, enabled: Bool, on preferences: WKPreferences) -> Bool {
        let featuresSelector = NSSelectorFromString("_features")
        let setSelector = NSSelectorFromString("_setEnabled:forFeature:")
        guard (WKPreferences.self as AnyObject).responds(to: featuresSelector),
              preferences.responds(to: setSelector),
              let features = (WKPreferences.self as AnyObject).perform(featuresSelector)?.takeUnretainedValue() as? [NSObject],
              let feature = features.first(where: { ($0.value(forKey: "key") as? String) == key })
        else { return false }
        typealias SetFeature = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
        let imp = unsafeBitCast(preferences.method(for: setSelector), to: SetFeature.self)
        imp(preferences, setSelector, enabled, feature)
        return true
    }

    /// `-[WKWebView _requestActiveNowPlayingSessionInfo:]` (WebKit testing SPI).
    static func activeNowPlayingSessionInfo(of webView: WKWebView) async -> (active: Bool, registered: Bool)? {
        let selector = NSSelectorFromString("_requestActiveNowPlayingSessionInfo:")
        guard webView.responds(to: selector) else { return nil }
        return await withCheckedContinuation { continuation in
            typealias Callback = @convention(block) (Bool, Bool, NSString?, Double, Double, Int) -> Void
            let callback: Callback = { active, registered, _, _, _, _ in
                continuation.resume(returning: (active, registered))
            }
            typealias Request = @convention(c) (AnyObject, Selector, Callback) -> Void
            let imp = unsafeBitCast(webView.method(for: selector), to: Request.self)
            imp(webView, selector, callback)
        }
    }
}
