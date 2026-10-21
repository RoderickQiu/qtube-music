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

/// The bridge at a track change on a broken network, and when its document is being replaced (live soak 2026-10-21:
/// Wi-Fi brownouts left WebKit's pooled connections dead, so YouTube's player request for the next track hung and failed).
@Suite struct QTBridgeTrackChangeTests {
    private func makePage() -> JSContext {
        let ctx = JSContext()!
        ctx.exceptionHandler = { _, e in Issue.record("JS: \(e?.toString() ?? "?")") }
        ctx.evaluateScript(QTBridgeKeepAliveTests.fakePage)
        // YouTube's player takes a new id at once; its length and stream come with the player response.
        ctx.evaluateScript("""
            var __stops = 0; __p.stopVideo = function () { __stops++; this.ps = 5; __video.paused = true; };
            __p.loadVideoById = function (a) { this.vid = a.videoId; this.t = 0; this.d = 0; this.ps = -1;
              __video.paused = true; __video.currentTime = 0; __video.duration = NaN; __video.readyState = 0; };
            """)
        ctx.evaluateScript(QTWebPlaybackBridgeScript.keepAlive)
        ctx.evaluateScript(QTWebPlaybackBridgeScript.bridge)
        ctx.evaluateScript("""
            __advance(300); __qtBridge.load('SONG', 30, true, 2);
            __p.t = 30; __p.d = 200; __p.ps = 1; __video.paused = false; __video.readyState = 4; __advance(10); __fire('playing')
            """)
        return ctx
    }

    private func lastState(_ ctx: JSContext) -> [String: Any]? {
        ctx.evaluateScript("__posts.filter(function (m) { return m.type === 'state'; }).pop()").toDictionary() as? [String: Any]
    }

    @Test func aTrackWhosePlayerRequestHasntAnsweredIsReportedWithoutALength() throws {
        let ctx = makePage()
        ctx.evaluateScript("__qtBridge.load('NEXTNEXTNEX', 0, true, 3); __advance(10)")
        let s = try #require(lastState(ctx).flatMap(QTWebPlaybackSample.init))
        #expect(s.generation == 3 && s.videoID == "NEXTNEXTNEX" && s.matchesLoad)
        #expect(s.paused && s.duration == 0 && s.readyState == 0 && s.ad == nil,
                "the shape the engine takes for a page still waiting on the network, not one refusing to start")
        #expect(!ctx.evaluateScript("__posts.some(function (m) { return m.type === 'ended' && m.gen === 3; })").toBool())
    }

    @Test func aRetiredDocumentStopsHoldsAndGoesQuiet() {
        let ctx = makePage()
        #expect(!ctx.evaluateScript("__video.paused").toBool())
        #expect(ctx.evaluateScript("__qtBridge.retire(3)").toBool())
        #expect(ctx.evaluateScript("__video.paused").toBool() && ctx.evaluateScript("__stops").toInt32() == 1)
        #expect(ctx.evaluateScript("__qtBridge.isFrozen()").toBool(), "its timers are frozen")
        // YouTube's player there moves on to its own pick and starts it: held at once, and nothing it says counts.
        ctx.evaluateScript("var before = __posts.length; __p.vid = 'YTPICK00000'; __p.d = 180; __p.playVideo(); __fire('play')")
        #expect(ctx.evaluateScript("__video.paused").toBool())
        #expect(ctx.evaluateScript("__posts.length > before && __posts.slice(before).every(function (m) { return m.gen === -1; })").toBool())
    }

    @Test func theNewDocumentIgnoresARetireMeantForTheOldOne() {
        let ctx = makePage()
        #expect(!ctx.evaluateScript("__qtBridge.retire(2)").toBool())
        #expect(!ctx.evaluateScript("__video.paused").toBool() && ctx.evaluateScript("__stops").toInt32() == 0)
    }
}
