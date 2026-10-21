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
    var __video = { currentTime: 0, duration: 0, paused: false, readyState: 4, videoWidth: 0, videoHeight: 0, plays: 0,
      pause() { this.paused = true; }, play() { this.paused = false; this.plays++; } };
    var __p = { vid: 'OLD', ad: false, t: 0, d: 200, ps: 1,
      getPlayerState() { return this.ps; }, getCurrentTime() { return this.t; }, getDuration() { return this.d; },
      getVideoData() { return { video_id: this.vid }; }, getPresentingPlayerType() { return this.ad ? 2 : 1; },
      classList: { contains(c) { return __p.ad && c === 'ad-showing'; } },
      addEventListener() {}, querySelector() { return __video; },
      loadVideoById(a) { __loads.push(a.videoId); }, cueVideoById(a) { __loads.push(a.videoId); },
      setVolume() {}, mute() {}, unMute() {}, pauseVideo() { __video.paused = true; },
      playVideo() { if (!(this.ad && this.adIgnoresPlay)) __video.paused = false; } };
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

    // MARK: Pre-rolls and the hold (live soak 2026-10-21: Song⇄Video's fallback reload was cued, so its pre-roll sat
    // paused and the queue called it an interruption)

    private func runTimers(_ ctx: JSContext) {
        ctx.evaluateScript("__timers.splice(0).forEach(f => f());")
    }

    private func isPaused(_ ctx: JSContext) -> Bool { ctx.evaluateScript("__video.paused").toBool() }

    /// The pre-roll starts on the page (YouTube rolls it even for a cued item).
    private func rollPreRoll(_ ctx: JSContext) {
        ctx.evaluateScript("__p.vid = 'AD1'; __p.ad = true; __video.duration = 15; __video.currentTime = 0; __video.paused = false;")
    }

    @Test func aCuedLoadHoldsItsPreRollAndPlayPlaysTheAdOn() {
        let ctx = makePage()
        ctx.evaluateScript("__qtBridge.load('VIDEO', 179, false, 2)")
        rollPreRoll(ctx)
        runTimers(ctx)
        #expect(isPaused(ctx), "a cued load is held: its pre-roll too")
        // Play drops the hold. YouTube's player may ignore playVideo for a paused ad: its media element plays it on.
        ctx.evaluateScript("__p.adIgnoresPlay = true; __qtBridge.play()")
        runTimers(ctx)
        #expect(!isPaused(ctx) && ctx.evaluateScript("__video.plays").toInt32() == 1)
        #expect(!ctx.evaluateScript("__qtBridge.sample().paused").toBool())
    }

    @Test func anAutoplayingLoadLetsItsPreRollPlay() {
        let ctx = makePage()
        ctx.evaluateScript("__qtBridge.load('VIDEO', 179, true, 2)")
        rollPreRoll(ctx)
        runTimers(ctx)
        #expect(!isPaused(ctx))
        // Content after it: nothing replays the media by itself.
        ctx.evaluateScript("__p.vid = 'VIDEO'; __p.ad = false; __p.t = 179; __video.duration = 220;")
        runTimers(ctx)
        #expect(!isPaused(ctx) && ctx.evaluateScript("__video.plays").toInt32() == 0)
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
