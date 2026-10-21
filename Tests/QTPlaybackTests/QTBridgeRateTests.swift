import Foundation
import JavaScriptCore
import Testing
@testable import QTPlayback

/// The rate script with the bridge in JavaScriptCore, against a fake YouTube Music page on a manual clock: the speed
/// goes on YouTube's player and the media element (pitch kept), a fresh page starts at the bootstrap's speed, ads play
/// at 1×, a page that puts its own rate back is overruled without looping, samples report the media's rate, and the
/// end window widens with the speed.
@Suite struct QTBridgeRateTests {
    /// `#movie_player` (its own rate, set only through `setPlaybackRate`), one `<video>`, an ad switch (`__ad`), and
    /// timers on a clock that `__advance(ms)` moves (`Date.now` included).
    private static let fakePage = """
    var window = this; var __posts = []; var __listeners = {}; var __ad = false;
    var __now = 1000000; Date.now = function () { return __now; };
    var __timers = new Map(); var __nextTimer = 1;
    function __add(fn, ms, every) { var id = __nextTimer++; __timers.set(id, { fn: fn, ms: Math.max(1, +ms || 0), due: __now + (+ms || 0), every: every }); return id; }
    function setTimeout(fn, ms) { return __add(fn, ms, false); }
    function setInterval(fn, ms) { return __add(fn, ms, true); }
    function clearTimeout(id) { __timers.delete(id); } function clearInterval(id) { __timers.delete(id); }
    function __advance(ms) {
      var end = __now + ms;
      for (;;) {
        var next = null;
        __timers.forEach(function (t, id) { if (t.due <= end && (!next || t.due < next.t.due)) next = { id: id, t: t }; });
        if (!next) break;
        __now = next.t.due;
        if (next.t.every) next.t.due += next.t.ms; else __timers.delete(next.id);
        next.t.fn();
      }
      __now = end;
    }
    function __fire(type) { (__listeners[type] || []).slice().forEach(function (f) { f({ target: __video }); }); }
    function __last() { for (var i = __posts.length - 1; i >= 0; i--) if (__posts[i].type === 'state') return __posts[i]; return null; }
    function getComputedStyle() { return { visibility: 'visible' }; }
    function MutationObserver() { this.observe = function () {}; }
    var location = { pathname: '/watch' };
    var __video = { currentTime: 30, duration: 200, paused: false, readyState: 4, videoWidth: 0, videoHeight: 0,
                    playbackRate: 1, preservesPitch: false, pause() { this.paused = true; } };
    var __p = { vid: 'SONG', t: 30, d: 200, ps: 1, rate: 1,
      getPlayerState() { return this.ps; }, getCurrentTime() { return this.t; }, getDuration() { return this.d; },
      getVideoData() { return { video_id: this.vid }; }, getPresentingPlayerType() { return __ad ? 2 : 1; },
      getPlaybackRate() { return this.rate; }, setPlaybackRate(r) { this.rate = r; },
      classList: { contains(c) { return __ad && c === 'ad-showing'; } }, addEventListener() {}, querySelector() { return __video; },
      loadVideoById() {}, cueVideoById() {}, setVolume() {}, mute() {}, unMute() {},
      pauseVideo() { __video.paused = true; this.ps = 2; }, playVideo() { __video.paused = false; this.ps = 1; } };
    var document = { getElementById(id) { return id === 'movie_player' ? __p : null; },
      querySelector() { return null; },
      addEventListener(type, f) { (__listeners[type] = __listeners[type] || []).push(f); },
      documentElement: { classList: { toggle() {} } } };
    window.webkit = { messageHandlers: { qtPlayback: { postMessage(m) { __posts.push(m); } } } };
    """

    private func makePage(bootRate: Double = 1) -> JSContext {
        let ctx = JSContext()!
        ctx.exceptionHandler = { _, e in Issue.record("JS: \(e?.toString() ?? "?")") }
        ctx.evaluateScript(Self.fakePage)
        ctx.evaluateScript(QTWebPlaybackBridgeScript.bootstrap(generation: 1, videoID: "SONG", hold: false, volume: 1,
                                                               muted: false, silent: true, rate: bootRate))
        ctx.evaluateScript(QTWebPlaybackBridgeScript.rate)
        ctx.evaluateScript(QTWebPlaybackBridgeScript.bridge)
        ctx.evaluateScript("__advance(300)")   // the bridge attaches
        ctx.evaluateScript("__qtBridge.load('SONG', 30, true, 2); __advance(10)")
        return ctx
    }

    private func number(_ ctx: JSContext, _ expression: String) -> Double {
        ctx.evaluateScript(expression).toDouble()
    }

    @Test func aFreshPageStartsAtTheBootstrapSpeedWithPitchKept() {
        let ctx = makePage(bootRate: 1.5)
        ctx.evaluateScript("__fire('timeupdate')")
        #expect(number(ctx, "__video.playbackRate") == 1.5)
        #expect(number(ctx, "__p.rate") == 1.5, "YouTube's player agrees, so it doesn't put 1× back")
        #expect(ctx.evaluateScript("__video.preservesPitch").toBool())
        #expect(number(ctx, "__last().rate") == 1.5)
    }

    @Test func theRateCommandSetsItAndReportsAtOnce() {
        let ctx = makePage()
        #expect(number(ctx, "__last().rate") == 1)
        #expect(ctx.evaluateScript("__qtBridge.rate(2)").toBool())
        #expect(number(ctx, "__video.playbackRate") == 2 && number(ctx, "__p.rate") == 2)
        #expect(number(ctx, "__last().rate") == 2, "a forced report carries the new rate")
        // Out of range from the app: clamped in the page too.
        ctx.evaluateScript("__qtBridge.rate(9)")
        #expect(number(ctx, "__video.playbackRate") == 2)
        ctx.evaluateScript("__qtBridge.rate(0.1)")
        #expect(number(ctx, "__video.playbackRate") == 0.5)
    }

    @Test func adsPlayAtNormalSpeed() {
        let ctx = makePage(bootRate: 2)
        ctx.evaluateScript("__fire('timeupdate')")
        #expect(number(ctx, "__video.playbackRate") == 2)
        ctx.evaluateScript("__ad = true; __fire('timeupdate')")
        #expect(number(ctx, "__video.playbackRate") == 1 && number(ctx, "__p.rate") == 1)
        #expect(number(ctx, "__last().rate") == 1 && !ctx.evaluateScript("__last().ad").isNull)
        // Even when the app asks during the ad, and when the ad's own media starts.
        ctx.evaluateScript("__qtBridge.rate(1.5); __fire('loadedmetadata')")
        #expect(number(ctx, "__video.playbackRate") == 1)
        // The content's back: its speed again.
        ctx.evaluateScript("__ad = false; __fire('timeupdate')")
        #expect(number(ctx, "__video.playbackRate") == 1.5 && number(ctx, "__last().rate") == 1.5)
    }

    @Test func aRateThePagePutsBackIsOverruledWithoutLooping() {
        let ctx = makePage(bootRate: 1.5)
        // YouTube sets its own rate on a new source.
        ctx.evaluateScript("__video.playbackRate = 1; __fire('ratechange')")
        #expect(number(ctx, "__video.playbackRate") == 1.5)
        // A page that fights every change (resets and fires again, synchronously): bounded, no endless loop.
        ctx.evaluateScript("""
            var __fights = 0;
            document.addEventListener('ratechange', function () {
              if (__fights++ < 200) { __video.playbackRate = 1; __fire('ratechange'); }
            }, true);
            __advance(2000); __fire('ratechange');
            """)
        #expect(number(ctx, "__fights") > 6)
        #expect(number(ctx, "__qtRate.info().asserts") < 12, "re-asserts are capped per second")
        // The bridge's next sample puts it back anyway.
        ctx.evaluateScript("__fire('timeupdate')")
        #expect(number(ctx, "__video.playbackRate") == 1.5)
    }

    @Test func theEndWindowWidensWithTheSpeed() {
        // 0.8 s before the end: within half a second of listening at 2×, not at 1×.
        let normal = makePage()
        normal.evaluateScript("__fire('timeupdate'); __p.t = 199.2; __fire('timeupdate')")
        #expect(!normal.evaluateScript("__posts.some(function (m) { return m.type === 'ended'; })").toBool())
        let fast = makePage(bootRate: 2)
        fast.evaluateScript("__fire('timeupdate'); __p.t = 199.2; __fire('timeupdate')")
        #expect(fast.evaluateScript("__posts.some(function (m) { return m.type === 'ended'; })").toBool())
    }

    @Test func theRateScriptIsSmallAndSeparateFromTheBridge() {
        #expect(QTWebPlaybackBridgeScript.rate.split(separator: "\n").count < 45)
        #expect(QTWebPlaybackBridgeScript.rate.contains("preservesPitch"))
        #expect(QTWebPlaybackBridgeScript.rate.contains("setPlaybackRate"))
        #expect(QTWebPlaybackBridgeScript.bridge.contains("__qtRate"))
    }
}
