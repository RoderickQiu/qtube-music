import Foundation
import JavaScriptCore
import Testing
@testable import QTPlayback

/// The keep-alive script with the bridge in JavaScriptCore, against a fake YouTube Music page with a manual clock:
/// the activity stamp `_lact` stays fresh while the app wants music, a "Still listening?" prompt is answered even when
/// it shows after the pause (no media event), and a pause the app asked for is left alone.
@Suite struct QTBridgeKeepAliveTests {
    /// `#movie_player`, one `<video>`, the prompt (when `__prompt` is set), and timers on a clock that `__advance(ms)`
    /// moves (`Date.now` included).
    static let fakePage = """
    var window = this; var __posts = []; var __clicks = 0; var __prompt = false; var __listeners = {};
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
    function __fire(type) { (__listeners[type] || []).forEach(function (f) { f({ target: __video }); }); }
    function getComputedStyle() { return { visibility: 'visible' }; }
    function MutationObserver() { this.observe = function () {}; }
    var location = { pathname: '/watch' };
    var __video = { currentTime: 30, duration: 200, paused: false, readyState: 4, videoWidth: 0, videoHeight: 0, pause() { this.paused = true; } };
    var __p = { vid: 'SONG', t: 30, d: 200, ps: 1,
      getPlayerState() { return this.ps; }, getCurrentTime() { return this.t; }, getDuration() { return this.d; },
      getVideoData() { return { video_id: this.vid }; }, getPresentingPlayerType() { return 1; },
      classList: { contains() { return false; } }, addEventListener() {}, querySelector() { return __video; },
      loadVideoById() {}, cueVideoById() {}, setVolume() {}, mute() {}, unMute() {},
      pauseVideo() { __video.paused = true; this.ps = 2; }, playVideo() { __video.paused = false; this.ps = 1; } };
    var __button = { click() { __clicks++; __prompt = false; __p.playVideo(); } };
    var document = { getElementById(id) { return id === 'movie_player' ? __p : null; },
      querySelector(sel) { return __prompt && sel.indexOf('ytmusic-you-there-renderer') >= 0 ? __button : null; },
      addEventListener(type, f) { (__listeners[type] = __listeners[type] || []).push(f); },
      documentElement: { classList: { toggle() {} } } };
    window.webkit = { messageHandlers: { qtPlayback: { postMessage(m) { __posts.push(m); } } } };
    """

    private func makePage() -> JSContext {
        let ctx = JSContext()!
        ctx.exceptionHandler = { _, e in Issue.record("JS: \(e?.toString() ?? "?")") }
        ctx.evaluateScript(Self.fakePage)
        ctx.evaluateScript(QTWebPlaybackBridgeScript.keepAlive)
        ctx.evaluateScript(QTWebPlaybackBridgeScript.bridge)
        ctx.evaluateScript("__advance(300)")   // the bridge attaches
        ctx.evaluateScript("__qtBridge.load('SONG', 30, true, 2); __advance(10)")
        return ctx
    }

    private func number(_ ctx: JSContext, _ expression: String) -> Double {
        ctx.evaluateScript(expression).toDouble()
    }

    @Test func theActivityStampStaysFreshWhileListening() {
        let ctx = makePage()
        ctx.evaluateScript("__fire('timeupdate'); __advance(61000)")
        let now = number(ctx, "__now")
        #expect(now - number(ctx, "window._lact") < 61000)
        #expect(number(ctx, "__qtKeepAlive.info().stamps") >= 1)
        // Paused by the listener: no stamping (YouTube may let the session go idle).
        ctx.evaluateScript("__qtBridge.pause(); var before = __qtKeepAlive.info().stamps; __advance(180000)")
        #expect(number(ctx, "__qtKeepAlive.info().stamps - before") == 0)
    }

    @Test func aPromptThatShowsAfterThePauseIsAnswered() {
        let ctx = makePage()
        // The page pauses itself; the media event comes first, the prompt a few seconds later.
        ctx.evaluateScript("__p.pauseVideo(); __fire('pause')")
        #expect(ctx.evaluateScript("__qtKeepAlive.info().retrying").toBool())
        #expect(number(ctx, "__clicks") == 0)
        ctx.evaluateScript("__advance(3000); __prompt = true; __advance(2500)")
        #expect(number(ctx, "__clicks") == 1, "answered by the retry loop, without a media event")
        #expect(!ctx.evaluateScript("__video.paused").toBool())
        // Playing again: the next report stops the loop.
        ctx.evaluateScript("__fire('play')")
        #expect(!ctx.evaluateScript("__qtKeepAlive.info().retrying").toBool())
    }

    @Test func aPromptWithoutAnyPauseIsAnsweredOnTheMinute() {
        let ctx = makePage()
        ctx.evaluateScript("__fire('timeupdate'); __prompt = true; __advance(61000)")
        #expect(number(ctx, "__clicks") == 1)
    }

    @Test func theListenersPauseIsLeftAlone() {
        let ctx = makePage()
        ctx.evaluateScript("__qtBridge.pause(); __prompt = true; __advance(120000)")
        #expect(number(ctx, "__clicks") == 0)
        #expect(!ctx.evaluateScript("__qtKeepAlive.info().retrying").toBool())
    }

    @Test func theRetryLoopGivesUpAfterHalfAMinute() {
        let ctx = makePage()
        ctx.evaluateScript("__p.pauseVideo(); __fire('pause'); __advance(40000)")
        #expect(!ctx.evaluateScript("__qtKeepAlive.info().retrying").toBool())
    }

    @Test func keepAliveStaysSmallAndSeparateFromTheBridge() {
        #expect(QTWebPlaybackBridgeScript.keepAlive.split(separator: "\n").count < 45)
        #expect(QTWebPlaybackBridgeScript.keepAlive.contains("_lact"))
        #expect(QTWebPlaybackBridgeScript.bridge.contains("__qtKeepAlive"))
    }
}
