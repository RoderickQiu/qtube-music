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

    /// `seconds` of the watch's clock, one at a time, letting the engine and the fake page answer in between.
    func tick(_ queue: QTQueueController, _ clock: ManualClock, _ seconds: Int) async throws {
        for _ in 0..<seconds {
            clock.now += 1
            queue.superviseTick()
            try await Task.sleep(for: .milliseconds(40))
        }
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
        try await pages.until { pages.engine.state.status != .loading }
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
        try await tick(queue, clock, 3)
        try await pages.until { pages.calls(on: .main, "play").count == 1 }   // Play again first
        #expect(notices.list.isEmpty, "a track that never started isn't an interruption")
        try await tick(queue, clock, 8)
        try await pages.until { pages.navigations.count == 2 && pages.engine.state.status == .playing }
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
        for _ in 0..<40 where notices.list.isEmpty { try await tick(queue, clock, 1) }
        #expect(notices.list == [.interrupted], "said once, after a fresh page didn't start it either")
        #expect(pages.navigations.count == 2, "one fresh page, not a loop")
        #expect(!queue.wantsPlayback && pages.engine.state.status == .paused)
        try await tick(queue, clock, 20)
        #expect(notices.list.count == 1 && pages.navigations.count == 2)
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
