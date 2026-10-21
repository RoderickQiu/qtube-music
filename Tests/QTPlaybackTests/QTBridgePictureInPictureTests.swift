import Foundation
import JavaScriptCore
import Testing
@testable import QTPlayback

/// The Picture in Picture script with the bridge in JavaScriptCore, on `QTBridgeKeepAliveTests`' fake page: the
/// listener's Play and Pause in the PiP window (and closing it) are theirs — the bridge neither re-pauses their Play
/// nor leaves their pause looking like one nobody asked for — while the end of an item stays held.
@Suite struct QTBridgePictureInPictureTests {
    private func makePage(inPictureInPicture: Bool = true) -> JSContext {
        let ctx = JSContext()!
        ctx.exceptionHandler = { _, e in Issue.record("JS: \(e?.toString() ?? "?")") }
        ctx.evaluateScript(QTBridgeKeepAliveTests.fakePage)
        ctx.evaluateScript("""
        __video.webkitPresentationMode = '\(inPictureInPicture ? "picture-in-picture" : "inline")';
        __video.webkitSetPresentationMode = function (m) { this.webkitPresentationMode = m; };
        """)
        ctx.evaluateScript(QTWebPlaybackBridgeScript.keepAlive)
        ctx.evaluateScript(QTWebPlaybackBridgeScript.pictureInPicture)
        ctx.evaluateScript(QTWebPlaybackBridgeScript.bridge)
        ctx.evaluateScript("__qtBridge.load('SONG', 30, true, 2); __advance(300); __fire('timeupdate')")
        return ctx
    }

    /// What the bridge said about the listener in PiP, in order (true = played).
    private func pipPosts(_ ctx: JSContext) -> [Bool] {
        (ctx.evaluateScript("__posts.filter(function (m) { return m.type === 'pip'; }).map(function (m) { return m.playing; })")
            .toArray() as? [Bool]) ?? []
    }

    private func paused(_ ctx: JSContext) -> Bool { ctx.evaluateScript("__video.paused").toBool() }

    // WebKit plays and pauses the media itself from the PiP window: the player follows (state 1 / 2) and media events fire.
    private func listenerPauses(_ ctx: JSContext) { ctx.evaluateScript("__video.paused = true; __p.ps = 2; __fire('pause')") }
    private func listenerPlays(_ ctx: JSContext) { ctx.evaluateScript("__video.paused = false; __p.ps = 1; __fire('play')") }

    @Test func pauseThenPlayInTheWindowAreTheListeners() {
        let ctx = makePage()
        listenerPauses(ctx)
        #expect(pipPosts(ctx) == [false])
        #expect(!ctx.evaluateScript("__qtKeepAlive.info().retrying").toBool(), "held: no prompt to answer")
        // Paused a while: the engine freezes the page.
        #expect(ctx.evaluateScript("__qtBridge.freeze()").toBool())
        listenerPlays(ctx)
        #expect(pipPosts(ctx) == [false, true])
        #expect(!paused(ctx), "their Play isn't re-paused by the hold")
        #expect(!ctx.evaluateScript("__qtBridge.isFrozen()").toBool(), "and the page thawed itself")
    }

    @Test func playInTheWindowAfterTheAppPausedWins() {
        let ctx = makePage()
        ctx.evaluateScript("__qtBridge.pause()")
        #expect(pipPosts(ctx).isEmpty, "the app's own pause is no news")
        listenerPlays(ctx)
        #expect(pipPosts(ctx) == [true] && !paused(ctx))
    }

    @Test func outsidePictureInPictureTheHoldStillHolds() {
        let ctx = makePage(inPictureInPicture: false)
        ctx.evaluateScript("__qtBridge.pause()")
        listenerPlays(ctx)   // YouTube starting the media on its own
        #expect(paused(ctx) && pipPosts(ctx).isEmpty)
        // And a pause the page makes by itself stays the page's (the queue undoes it).
        ctx.evaluateScript("__qtBridge.play()")
        listenerPauses(ctx)
        #expect(pipPosts(ctx).isEmpty)
    }

    @Test func closingTheWindowPausesForTheListener() {
        let ctx = makePage()
        // The listener closes the window: WebKit returns the video inline, then pauses it.
        ctx.evaluateScript("__video.webkitPresentationMode = 'inline'; __fire('webkitpresentationmodechanged'); __advance(200)")
        listenerPauses(ctx)
        #expect(pipPosts(ctx) == [false])
    }

    @Test func theAppLeavingPictureInPictureIsNoClose() {
        let ctx = makePage()
        ctx.evaluateScript("__qtBridge.pip(false); __fire('webkitpresentationmodechanged'); __advance(200)")
        listenerPauses(ctx)
        #expect(pipPosts(ctx).isEmpty)
        // Nor is a pause long after the listener closed it.
        let late = makePage()
        late.evaluateScript("__video.webkitPresentationMode = 'inline'; __fire('webkitpresentationmodechanged'); __advance(5000)")
        listenerPauses(late)
        #expect(pipPosts(late).isEmpty)
    }

    @Test func theEndOfTheItemStaysHeld() {
        let ctx = makePage()
        ctx.evaluateScript("__p.t = 199.8; __video.currentTime = 199.8; __fire('timeupdate')")
        #expect(ctx.evaluateScript("__posts.some(function (m) { return m.type === 'ended'; })").toBool())
        listenerPlays(ctx)   // YouTube's own autoplay pick, in the PiP window
        #expect(paused(ctx) && pipPosts(ctx).isEmpty)
    }

    @Test func theScriptStaysSmallAndSeparateFromTheBridge() {
        #expect(QTWebPlaybackBridgeScript.pictureInPicture.split(separator: "\n").count < 25)
        #expect(QTWebPlaybackBridgeScript.bridge.contains("__qtPip"))
    }
}
