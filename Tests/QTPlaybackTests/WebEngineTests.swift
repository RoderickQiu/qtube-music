import Foundation
import QTCore
import Testing
import WebKit
@testable import QTPlayback

@MainActor
@Suite struct WebEngineTests {
    @Test func songAndVideoModesPickTheRightVideoID() {
        var atv = PB.track("atv")
        atv.counterpart = QTCounterpart(videoId: "omv", musicVideoType: .omv)
        #expect(QTWebPlaybackEngine.videoID(for: QTPlaybackItem(track: atv, mode: .song)) == "atv")
        #expect(QTWebPlaybackEngine.videoID(for: QTPlaybackItem(track: atv, mode: .video)) == "omv")

        var omv = PB.track("omv2")
        omv.musicVideoType = .omv
        omv.counterpart = QTCounterpart(videoId: "atv2", musicVideoType: .atv)
        #expect(QTWebPlaybackEngine.videoID(for: QTPlaybackItem(track: omv, mode: .song)) == "atv2")
        #expect(QTWebPlaybackEngine.videoID(for: QTPlaybackItem(track: omv, mode: .video)) == "omv2")

        let plain = PB.track("plain")
        #expect(QTWebPlaybackEngine.videoID(for: QTPlaybackItem(track: plain, mode: .video)) == "plain")
    }

    @Test func bridgeSamplesParse() throws {
        let content = try #require(QTWebPlaybackSample([
            "type": "state", "gen": 3, "vid": "abc", "match": true, "t": 12.5, "d": 200.0, "paused": false, "ps": 1,
            "buffering": false, "ad": NSNull(),
        ]))
        #expect(content.generation == 3 && content.videoID == "abc" && content.matchesLoad)
        #expect(content.time == 12.5 && content.duration == 200 && !content.paused && content.ad == nil)

        let ad = try #require(QTWebPlaybackSample([
            "gen": 3, "vid": "abc", "match": true, "t": 0.0, "d": 200.0, "paused": false, "ps": -1,
            "ad": ["duration": 15.0, "remaining": 11.2, "skippableIn": 2.0] as [String: Any],
        ]))
        #expect(ad.ad == QTWebPlaybackSample.Ad(duration: 15, remaining: 11.2, skippableIn: 2))

        let unskippable = try #require(QTWebPlaybackSample(["gen": 1, "ad": ["duration": 6.0, "remaining": 6.0] as [String: Any]]))
        #expect(unskippable.ad?.skippableIn == nil)
        #expect(unskippable.matchesLoad == false)
        #expect(QTWebPlaybackSample(["vid": "no generation"]) == nil)
    }

    /// The bridge stays tiny (Kaset's ~6k-line JS bridge is the anti-pattern this engine avoids).
    @Test func javascriptStaysUnderThreeHundredLines() {
        let js = [QTWebPlaybackBridgeScript.bridge, QTWebPlaybackBridgeScript.mediaSessionShield, QTWebPlaybackBridgeScript.silence,
                  QTWebPlaybackBridgeScript.bootstrap(generation: 1, videoID: "x", hold: false, volume: 1, muted: false, silent: false)]
        let lines = js.joined(separator: "\n").split(separator: "\n").count
        #expect(lines < 300, "\(lines) lines")
        #expect(QTWebPlaybackBridgeScript.bridge.contains("loadVideoById"))
        #expect(!QTWebPlaybackBridgeScript.bridge.contains("setActionHandler"), "the page's media session is never used")
    }

    /// The video surface is its own small script; the bridge only tells it when to show (and boots with it).
    @Test func videoSurfaceStaysSmallAndSeparate() {
        let lines = QTWebPlaybackBridgeScript.videoSurface.split(separator: "\n").count
        #expect(lines < 190, "\(lines) lines")
        // Burned-in letterbox and pillarbox bars are both measured and cropped.
        #expect(QTWebPlaybackBridgeScript.videoSurface.contains("pictureBars"))
        #expect(QTWebPlaybackBridgeScript.videoSurface.contains("requestVideoFrameCallback"))
        #expect(QTWebPlaybackBridgeScript.bridge.contains("__qtVideo"))
        let boot = QTWebPlaybackBridgeScript.bootstrap(generation: 2, videoID: "x", hold: true, volume: 1, muted: false,
                                                       silent: true, present: true, quality: "hd720")
        #expect(boot.contains("\"present\":true") && boot.contains("\"quality\":\"hd720\""))
        #expect(boot.contains("\"standby\":false"))
        let standby = QTWebPlaybackBridgeScript.bootstrap(generation: 3, videoID: "x", hold: false, volume: 0, muted: true,
                                                          silent: false, standby: true)
        #expect(standby.contains("\"standby\":true") && standby.contains("\"muted\":true"))
        // The crossfade command exists on the bridge.
        #expect(QTWebPlaybackBridgeScript.bridge.contains("fade(to, ms, dir, muted)"))
    }

    /// The rendition follows the slot: the panel's thumbnail never pulls 1080p, a full Stage does.
    @Test func videoQualityFitsTheSlot() {
        #expect(QTWebVideoOutput.quality(forPixelHeight: 176) == "small")
        #expect(QTWebVideoOutput.quality(forPixelHeight: 400) == "medium")
        #expect(QTWebVideoOutput.quality(forPixelHeight: 900) == "hd720")
        #expect(QTWebVideoOutput.quality(forPixelHeight: 1800) == "hd1080")
        let report = QTModeSwitchReport(videoID: "v", from: .song, to: .video, requested: 40, landed: 40.3, latency: 0.9)
        #expect(abs(report.offset - 0.3) < 0.0001)
        // An in-page switch is silent until the new rendition plays; a seamless one never is.
        #expect(report.gap == 0.9 && !report.isSeamless)
        let seamless = QTModeSwitchReport(videoID: "v", from: .video, to: .song, requested: 50, landed: 49.98, latency: 3,
                                          gap: 0, isSeamless: true)
        #expect(seamless.gap == 0 && seamless.isSeamless)
    }

    /// Video fields of a bridge sample (frame readiness, PiP).
    @Test func sampleCarriesVideoFields() throws {
        let s = try #require(QTWebPlaybackSample(["gen": 3, "vw": 1920.0, "vh": 1080.0, "rs": 4, "pip": true]))
        #expect(s.videoWidth == 1920 && s.videoHeight == 1080 && s.readyState == 4 && s.isPictureInPicture)
        let empty = try #require(QTWebPlaybackSample(["gen": 3]))
        #expect(empty.videoWidth == 0 && !empty.isPictureInPicture && empty.pictureBars == .zero)
        let bars = try #require(QTWebPlaybackSample(["gen": 3, "pic": [0.12, 0, 0.12, 0]]))
        #expect(bars.pictureBars == QTVideoPictureBars(left: 0.12, top: 0, right: 0.12, bottom: 0))
    }

    /// The Now Playing guarantee depends on this WebKit feature; fail loudly if a WebKit update removes it.
    @Test func webKitStillOffersRunningMediaOutsideTheGPUProcess() {
        #expect(QTWebKitTuning.runMediaInWebContentProcess(WKPreferences()))
        #expect(QTWebKitTuning.setFeature("NoSuchFeatureQT", enabled: false, on: WKPreferences()) == false)
    }

    @Test func freeEngineCapabilitiesAndUnplayableItems() async {
        let engine = QTWebPlaybackEngine(configuration: .init(isSilent: true), dataStore: .nonPersistent())
        #expect(engine.capabilities == .web && engine.capabilities.contains(.visualizerData))
        #expect(!engine.capabilities.contains(.gapless))
        await #expect(throws: QTPlaybackError.unavailable(.regionLocked)) {
            try await engine.load(QTPlaybackItem(track: PB.track("x", playable: false)), autoplay: true)
        }
        #expect(engine.state.status == .failed(.unavailable(.regionLocked)))
    }


    /// Live check against music.youtube.com (anonymous, silent). Off by default; `QT_LIVE=1 swift test …`.
    /// The fuller live run (ads, skip, Now Playing ownership, 10 advances) is `swift run QTPlaybackLab`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QT_LIVE"] == "1"))
    func livePlaysSeeksAndEnds() async throws {
        _ = NSApplication.shared  // WebKit only runs media for views in a window of an NSApplication process
        let engine = QTWebPlaybackEngine(configuration: .init(isSilent: true), dataStore: .nonPersistent())
        let controller = QTQueueController(engine: engine)
        let ids = ["dQw4w9WgXcQ", "kJQP7kiw5Fk"]
        await controller.play(ids.map { QTTrack(videoId: $0, title: $0, artists: [], duration: 0, musicVideoType: .omv) })
        try #require(controller.lastFailure == nil)
        // Wait out any ad (unskippable ones run ≤ 30 s).
        for _ in 0..<900 where !(engine.state.ad == nil && engine.state.status == .playing && engine.state.duration > 0) {
            if engine.state.ad?.canSkip == true { engine.skipAd() }
            try await Task.sleep(for: .milliseconds(100))
        }
        let t0 = engine.state.time
        try await Task.sleep(for: .seconds(3))
        #expect(engine.state.time - t0 > 2)
        engine.seek(to: engine.state.duration - 2)
        for _ in 0..<300 where controller.nowPlayingTrack?.videoId != ids[1] {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(controller.nowPlayingTrack?.videoId == ids[1])
        engine.shutdown()
    }
}
