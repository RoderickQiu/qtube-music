import Foundation
import QTCore
import Testing
import WebKit
@testable import QTPlayback

/// The web engine recovering on its own, with fake player pages behind `QTWebPageIO` (see `QTFakePlayerPages`): a
/// WebContent process that dies, a page that no longer takes commands, a page left over from a long sleep, and a page
/// that pauses itself (which is never frozen).
@MainActor
@Suite(.serialized) struct WebRecoveryTests {
    static let songID = QTModeSwitchBehaviourTests.songID

    func startSong(_ pages: QTFakePlayerPages) async throws {
        try await pages.engine.load(QTPlaybackItem(track: QTModeSwitchBehaviourTests.song, mode: .song, startTime: 30), autoplay: true)
        try await pages.until { pages.engine.state.status == .playing }
    }

    @Test func aCrashedPageReloadsWhereItWasWhilePlaying() async throws {
        let pages = QTFakePlayerPages()
        try await startSong(pages)
        #expect(pages.navigations.count == 1)
        pages.engine.webContentProcessDidTerminate()
        try await pages.until { pages.navigations.count == 2 && pages.engine.state.status == .playing }
        let url = try #require(pages.navigations.last?.absoluteString)
        #expect(url.contains("v=\(Self.songID)") && url.contains("t=30s"), "\(url)")
        #expect(pages.engine.state.item?.track.videoId == Self.songID)
    }

    @Test func aCrashWhilePausedNeedsNoPageUntilPlay() async throws {
        let pages = QTFakePlayerPages()
        try await startSong(pages)
        pages.engine.pause()
        pages.engine.webContentProcessDidTerminate()
        try await Task.sleep(for: .milliseconds(100))
        #expect(pages.navigations.count == 1, "nothing plays, so nothing loads")
        #expect(pages.engine.state.status == .paused && pages.engine.state.item != nil)
        pages.engine.play()
        try await pages.until { pages.navigations.count == 2 && pages.engine.state.status == .playing }
        #expect(pages.navigations.last?.absoluteString.contains("t=30s") == true)
    }

    @Test func playThatThePageDoesntTakeReloadsTheItem() async throws {
        let pages = QTFakePlayerPages()
        try await startSong(pages)
        pages.engine.pause()
        pages.refuses = ["play"]
        pages.engine.play()
        try await pages.until { pages.navigations.count == 2 }
        #expect(pages.navigations.last?.absoluteString.contains("v=\(Self.songID)") == true)
    }

    @Test func aLongSleepGetsAFreshPageOnPlayAShortOneDoesnt() async throws {
        let pages = QTFakePlayerPages()
        try await startSong(pages)
        pages.engine.pause()
        pages.engine.systemDidWake(after: 60)
        pages.engine.play()
        try await pages.until { pages.calls(on: .main, "play").count == 1 }
        #expect(pages.navigations.count == 1)
        pages.engine.pause()
        pages.engine.systemDidWake(after: 3 * 3600)
        pages.engine.play()
        try await pages.until { pages.navigations.count == 2 && pages.engine.state.status == .playing }
    }

    @Test func aPageThatPausedItselfIsNeverFrozen() async throws {
        let pages = QTFakePlayerPages(freezeAfterPause: .milliseconds(30))
        try await startSong(pages)
        // "Still listening?": the page pauses without being asked.
        pages.engine.receive(["type": "state", "gen": pages.engine.generation, "vid": Self.songID, "match": true, "t": 31.0,
                              "d": 200.0, "paused": true, "ps": 2, "buffering": false, "ad": NSNull(), "rs": 4])
        #expect(pages.engine.state.status == .paused)
        try await Task.sleep(for: .milliseconds(200))
        #expect(pages.calls(on: .main, "freeze").isEmpty, "its prompt has to stay answerable")
        // The listener's pause freezes it as before.
        pages.engine.pause()
        try await pages.until { !pages.calls(on: .main, "freeze").isEmpty }
    }

    // MARK: The queue over the web engine at a track change (live soak 2026-10-21)

    static let nextID = QTModeSwitchBehaviourTests.nextID

    /// A queue on the fake pages whose watch runs on a clock the test moves (from now: the engine's timeline is real).
    func queue(on pages: QTFakePlayerPages, clock: ManualClock) -> (QTQueueController, Notices) {
        clock.now = ProcessInfo.processInfo.systemUptime
        let queue = QTQueueController(engine: pages.engine, uptime: { clock.now }, supervision: nil)
        let notices = Notices()
        queue.onNotice = { notices.list.append($0) }
        return (queue, notices)
    }

    final class Notices { var list: [QTPlaybackNotice] = [] }

    /// `seconds` of the watch's clock, one at a time. After each tick the engine and the fake page answer first: the
    /// clock never moves on while a load is in flight, so the watch's steps follow the pages' answers, not machine load.
    func tick(_ queue: QTQueueController, _ clock: ManualClock, _ seconds: Int) async throws {
        for _ in 0..<seconds {
            clock.now += 1
            queue.superviseTick()
            try await settle(queue)
        }
    }

    /// Ticks until `condition` holds, at most `limit` seconds of the watch's clock.
    func tick(_ queue: QTQueueController, _ clock: ManualClock, until condition: () -> Bool, within limit: Int,
              sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0..<limit where !condition() { try await tick(queue, clock, 1) }
        if !condition() { Issue.record("not within \(limit) s of the watch's clock", sourceLocation: sourceLocation) }
    }

    /// The fake page's answers land (it replies after ~20 ms) and no load is left in flight.
    func settle(_ queue: QTQueueController) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 5
        repeat {
            try await Task.sleep(for: .milliseconds(30))
        } while queue.loadInFlight != nil && ProcessInfo.processInfo.systemUptime < end
    }

    /// Plays the song from near its end, then lets it end naturally (the bridge's `ended`).
    func playSongToItsEnd(_ queue: QTQueueController, _ pages: QTFakePlayerPages, _ clock: ManualClock,
                          offlineOnTheWay: Bool = false) async throws {
        await queue.play([QTModeSwitchBehaviourTests.song, QTModeSwitchBehaviourTests.next], startTime: 150)
        try await pages.until { pages.engine.state.status == .playing }
        if offlineOnTheWay {
            // The live soak's `offline` / `online` debug commands: only the engine hears them, the page plays on.
            pages.engine.networkChanged(available: false)
            try await tick(queue, clock, 25)
            pages.engine.networkChanged(available: true)
            try await tick(queue, clock, 5)
            #expect(pages.engine.state.status == .playing && pages.mainLoads.isEmpty && pages.navigations.count == 1,
                    "nothing reloads while the item plays")
        }
        pages.engine.receive(["type": "ended", "gen": pages.engine.generation])
        try await pages.until { queue.nowPlayingTrack?.videoId == Self.nextID && pages.mainLoads.count == 1 }
        try await pages.until { pages.engine.state.status != .loading && queue.loadInFlight == nil }
    }

    @Test func offlineThenOnlineThenANaturalEndPlaysTheNextTrack() async throws {
        let pages = QTFakePlayerPages()
        let clock = ManualClock()
        let (queue, notices) = queue(on: pages, clock: clock)
        try await playSongToItsEnd(queue, pages, clock, offlineOnTheWay: true)
        try await tick(queue, clock, 10)
        #expect(pages.engine.state.status == .playing && pages.engine.state.item?.track.videoId == Self.nextID)
        #expect(pages.mainLoads.map(\.autoplay) == [true] && pages.engine.intendsPlayback)
        #expect(queue.wantsPlayback && notices.list.isEmpty)
    }

    @Test func aNewTrackThePageWontStartIsPlayedAgainThenGetsAFreshPage() async throws {
        let pages = QTFakePlayerPages()
        let clock = ManualClock()
        let (queue, notices) = queue(on: pages, clock: clock)
        pages.refusesToStart = .inPage
        // The live sequence: offline, online, the song ends; the next track comes up paused at 0 and Play doesn't move it.
        try await playSongToItsEnd(queue, pages, clock, offlineOnTheWay: true)
        #expect(pages.engine.state.status == .paused && pages.engine.state.timeline.currentTime == 0)
        try await tick(queue, clock, until: { pages.calls(on: .main, "play").count == 1 }, within: 3)
        #expect(pages.navigations.count == 1, "Play again first")
        #expect(notices.list.isEmpty, "a track that never started isn't an interruption")
        try await tick(queue, clock, until: { pages.navigations.count == 2 }, within: 8)
        try await pages.until { pages.engine.state.status == .playing }
        let url = try #require(pages.navigations.last?.absoluteString)
        #expect(url.contains("v=\(Self.nextID)") && !url.contains("t="), "a fresh page at the start: \(url)")
        try await tick(queue, clock, 10)
        #expect(pages.engine.state.status == .playing && queue.wantsPlayback && notices.list.isEmpty)
        #expect(pages.navigations.count == 2)
    }

    @Test func aTrackNoPageWillStartIsReportedOnceAfterAFreshPage() async throws {
        let pages = QTFakePlayerPages()
        let clock = ManualClock()
        let (queue, notices) = queue(on: pages, clock: clock)
        await queue.play([QTModeSwitchBehaviourTests.song, QTModeSwitchBehaviourTests.next], startTime: 150)
        try await pages.until { pages.engine.state.status == .playing }
        pages.refusesToStart = .everywhere
        pages.engine.receive(["type": "ended", "gen": pages.engine.generation])
        try await pages.until { queue.nowPlayingTrack?.videoId == Self.nextID && pages.mainLoads.count == 1 }
        try await tick(queue, clock, until: { !notices.list.isEmpty }, within: 40)
        #expect(notices.list == [.interrupted], "said once, after a fresh page didn't start it either")
        #expect(pages.navigations.count == 2, "one fresh page, not a loop")
        #expect(!queue.wantsPlayback && pages.engine.state.status == .paused)
        try await tick(queue, clock, 20)
        #expect(notices.list.count == 1 && pages.navigations.count == 2)
    }

    @Test func underPictureInPictureANewTrackThatWontStartIsStillStarted() async throws {
        let pages = QTFakePlayerPages()
        pages.pictureInPicture = true
        let clock = ManualClock()
        let (queue, notices) = queue(on: pages, clock: clock)
        pages.refusesToStart = .inPage
        try await playSongToItsEnd(queue, pages, clock)
        #expect(pages.engine.video.isPictureInPictureActive && pages.engine.isPausedByListener)
        #expect(!pages.engine.isListenerPauseReported, "nobody paused it: the page didn't start it")
        #expect(queue.wantsPlayback, "not taken for the listener's pause as it arrived")
        try await tick(queue, clock, until: { pages.navigations.count == 2 }, within: 10)
        try await pages.until { pages.engine.state.status == .playing }
        #expect(queue.wantsPlayback && notices.list.isEmpty)
    }

    @Test func underPictureInPictureTheListenersReportedPauseOfAStartingTrackHolds() async throws {
        let pages = QTFakePlayerPages()
        pages.pictureInPicture = true
        let clock = ManualClock()
        let (queue, _) = queue(on: pages, clock: clock)
        pages.refusesToStart = .inPage
        try await playSongToItsEnd(queue, pages, clock)
        // Their pause in the PiP window, as the bridge reports it (before the state it changes).
        pages.engine.receive(["type": "pip", "gen": pages.engine.generation, "playing": false])
        pages.engine.receive(["type": "state", "gen": pages.engine.generation, "vid": Self.nextID, "match": true, "t": 0.0,
                              "d": 180.0, "paused": true, "ps": 2, "buffering": false, "ad": NSNull(), "rs": 4, "pip": true])
        try await tick(queue, clock, until: { !queue.wantsPlayback }, within: 3)
        let plays = pages.calls(on: .main, "play").count
        try await tick(queue, clock, 15)
        #expect(pages.calls(on: .main, "play").count == plays && pages.navigations.count == 1, "their pause holds")
    }

    @Test func aNativeItemNeverLeavesTheWebEngineAFreshPageToLoad() async throws {
        let pages = QTFakePlayerPages()
        try await startSong(pages)
        let native = QTNativePlaybackEngine(web: pages.engine, credentials: { nil })
        native.isNativeActive = true
        native.startNextLoadAfresh()
        #expect(!pages.engine.needsFreshPage, "the native item reloads natively; the page stays usable")
        native.isNativeActive = false
        native.startNextLoadAfresh()
        #expect(pages.engine.needsFreshPage, "the web engine plays it: its next load gets a fresh page")
    }

    // MARK: Song⇄Video into a pre-roll (live soak 2026-10-21)

    static let videoID = QTModeSwitchBehaviourTests.videoID

    /// Plays the song at 30 s, then switches to the video: the standby rolls an ad, so the switch reloads in the page,
    /// whose pre-roll comes up paused (`preRoll`).
    func switchIntoAPausedPreRoll(_ preRoll: QTFakePlayerPages.PreRoll) async throws
        -> (QTFakePlayerPages, QTQueueController, Notices, ManualClock) {
        let pages = QTFakePlayerPages()
        pages.standby = .rollsAnAd
        pages.preRoll = preRoll
        let clock = ManualClock()
        let (queue, notices) = queue(on: pages, clock: clock)
        await queue.play([QTModeSwitchBehaviourTests.song, QTModeSwitchBehaviourTests.next], startTime: 30)
        try await pages.until { pages.engine.pageAccount != nil && pages.engine.state.status == .playing }
        try await tick(queue, clock, 2)
        await queue.setMode(.video)
        #expect(pages.engine.lastSeamlessFallback == "standby ad")
        #expect(pages.mainLoads.last?.videoID == Self.videoID && pages.mainLoads.last?.autoplay == true)
        try await pages.until { pages.engine.state.ad != nil && pages.engine.state.status == .paused && queue.loadInFlight == nil }
        return (pages, queue, notices, clock)
    }

    @Test func aPausedPreRollAfterSongVideoIsPlayedNotCalledAnInterruption() async throws {
        let (pages, queue, notices, clock) = try await switchIntoAPausedPreRoll(.pausedUntilPlay)
        try await tick(queue, clock, until: { pages.engine.state.status == .playing && pages.engine.state.ad == nil }, within: 6)
        #expect(pages.engine.state.item?.mode == .video && queue.mode == .video)
        try await tick(queue, clock, 10)
        #expect(queue.wantsPlayback && notices.list.isEmpty && pages.navigations.count == 1)
        #expect(pages.calls(on: .main, "skipAd").isEmpty, "the ad played; nothing skipped it")
    }

    @Test func aPreRollThatStaysPausedGetsAFreshPageAtThePosition() async throws {
        let (pages, queue, notices, clock) = try await switchIntoAPausedPreRoll(.stuck)
        try await tick(queue, clock, until: { pages.calls(on: .main, "play").count == 1 }, within: 3)
        try await tick(queue, clock, 3)
        #expect(notices.list.isEmpty && queue.wantsPlayback, "an ad isn't \"Still listening?\"")
        try await tick(queue, clock, until: { pages.navigations.count == 2 }, within: 8)
        try await pages.until { pages.engine.state.status == .playing }
        let url = try #require(pages.navigations.last?.absoluteString)
        #expect(url.contains("v=\(Self.videoID)") && (url.contains("t=30s") || url.contains("t=31s")), "\(url)")
        try await tick(queue, clock, 10)
        #expect(pages.engine.state.status == .playing && queue.mode == .video && notices.list.isEmpty)
    }

    @Test func pausingWhileLoadingShowsPausedAtOnce() async throws {
        let pages = QTFakePlayerPages()
        let loading = Task { try await pages.engine.load(QTPlaybackItem(track: QTModeSwitchBehaviourTests.song, startTime: 12), autoplay: true) }
        try await pages.until { pages.engine.state.status == .loading }
        pages.engine.pause()
        #expect(pages.engine.state.status == .paused && !pages.engine.state.isBuffering)
        #expect(pages.engine.state.item?.track.videoId == Self.songID)
        _ = try? await loading.value
    }
}
