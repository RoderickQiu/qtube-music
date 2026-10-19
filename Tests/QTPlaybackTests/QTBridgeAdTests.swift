import Foundation
import JavaScriptCore
import Testing
@testable import QTPlayback

/// The bridge script against a fake YouTube Music player in JavaScriptCore: how samples are matched to the load
/// around ads. (R6: an ad that reported its own video id made the bridge resolve the load to the ad; the content
/// that followed never matched again and the app froze on "Ad · 0:00".)
@Suite struct QTBridgeAdTests {
    /// A minimal page: `#movie_player` with the player API the bridge reads, one `<video>`, manual timers.
    private static let fakePage = """
    var window = this; var __timers = []; var __posts = []; var __loads = [];
    function setTimeout(fn) { __timers.push(fn); return __timers.length; }
    function setInterval(fn) { __timers.push(fn); return __timers.length; }
    function clearTimeout() {} function clearInterval() {}
    function getComputedStyle() { return { visibility: 'visible' }; }
    function MutationObserver() { this.observe = function () {}; }
    var location = { pathname: '/watch' };
    var __video = { currentTime: 0, duration: 0, paused: false, readyState: 4, videoWidth: 0, videoHeight: 0 };
    var __p = { vid: 'OLD', ad: false, t: 0, d: 200, ps: 1,
      getPlayerState() { return this.ps; }, getCurrentTime() { return this.t; }, getDuration() { return this.d; },
      getVideoData() { return { video_id: this.vid }; }, getPresentingPlayerType() { return this.ad ? 2 : 1; },
      classList: { contains(c) { return __p.ad && c === 'ad-showing'; } },
      addEventListener() {}, querySelector() { return __video; },
      loadVideoById(a) { __loads.push(a.videoId); }, cueVideoById(a) { __loads.push(a.videoId); },
      setVolume() {}, mute() {}, unMute() {}, pauseVideo() {}, playVideo() {} };
    var document = { getElementById(id) { return id === 'movie_player' ? __p : null; },
      querySelector() { return null; }, addEventListener() {},
      documentElement: { classList: { toggle() {} } } };
    window.webkit = { messageHandlers: { qtPlayback: { postMessage(m) { __posts.push(m); } } } };
    """

    private func makePage() -> JSContext {
        let ctx = JSContext()!
        ctx.exceptionHandler = { _, e in Issue.record("JS: \(e?.toString() ?? "?")") }
        ctx.evaluateScript(Self.fakePage)
        ctx.evaluateScript(QTWebPlaybackBridgeScript.bridge)
        ctx.evaluateScript("__timers.splice(0).forEach(f => f());")   // attach
        return ctx
    }

    private func sample(_ ctx: JSContext) -> (vid: String, match: Bool, ad: Bool) {
        let s = ctx.evaluateScript("__qtBridge.sample()")!
        return (s.forProperty("vid").toString(), s.forProperty("match").toBool(), !s.forProperty("ad").isNull)
    }

    @Test func adReportingItsOwnIdDoesNotStealTheLoad() {
        let ctx = makePage()
        ctx.evaluateScript("__qtBridge.load('SONG', 58, true, 2)")
        // Pre-roll: the player reports the ad's id while it presents.
        ctx.evaluateScript("__p.vid = 'AD1'; __p.ad = true; __video.duration = 15; __video.currentTime = 3;")
        let ad = sample(ctx)
        #expect(ad.ad && ad.match, "the pre-roll belongs to this load")
        // The ad's media ran out; the player still presents it.
        ctx.evaluateScript("__video.currentTime = 15;")
        #expect(sample(ctx).match)
        // Content: the requested item plays under its own id and matches.
        ctx.evaluateScript("__p.vid = 'SONG'; __p.ad = false; __p.t = 58; __video.duration = 200; __video.currentTime = 58;")
        let content = sample(ctx)
        #expect(!content.ad && content.match)
        #expect(ctx.evaluateScript("__loads.length").toInt32() == 1, "no second load of the item")
    }

    @Test func swappedRenditionStillResolvesAndPostRollFromPreviousItemIsIgnored() {
        let ctx = makePage()
        // YouTube Music may play another id for the request (a video's song): the first new id is adopted.
        ctx.evaluateScript("__qtBridge.load('VIDEO', 0, true, 3); __p.vid = 'AUDIO'; __p.t = 1;")
        #expect(sample(ctx).match)
        // An ad that still carries the previous item's id isn't this load's.
        ctx.evaluateScript("__qtBridge.load('NEXT', 0, true, 4); __p.ad = true;")
        #expect(!sample(ctx).match)
        ctx.evaluateScript("__p.vid = 'NEXT'; __p.ad = false;")
        #expect(sample(ctx).match)
    }
}
