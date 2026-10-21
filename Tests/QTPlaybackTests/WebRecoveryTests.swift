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
