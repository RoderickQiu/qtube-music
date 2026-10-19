import Foundation
import QTCore
import Testing
import WebKit
@testable import QTPlayback

/// Real-playback robustness: error mapping, id validation, failure events, publish filtering.
@MainActor
@Suite struct PlaybackLiveTests {
    @Test func playerErrorsMapToSpecificFailures() {
        typealias M = QTWebPlaybackErrorMapper
        #expect(M.error(code: 100, status: "", reason: "") == .unavailable(.removed))
        #expect(M.error(code: 150, status: "", reason: "") == .unavailable(.removed))
        #expect(M.error(code: 2, status: "", reason: "") == .unavailable(.removed))
        #expect(M.error(code: 5, status: "", reason: "") == .engine("player error 5"))
        // Playability status (no onError for these).
        #expect(M.error(code: -1, status: "LOGIN_REQUIRED", reason: "Sign in to confirm your age") == .ageRestricted)
        #expect(M.error(code: -1, status: "LOGIN_REQUIRED", reason: "这是私享视频", ageGate: true) == .ageRestricted)
        #expect(M.error(code: -1, status: "LOGIN_REQUIRED", reason: "This video is private") == .unavailable(.removed))
        #expect(M.error(code: -1, status: "AGE_VERIFICATION_REQUIRED", reason: "") == .ageRestricted)
        #expect(M.error(code: -1, status: "CONTENT_CHECK_REQUIRED", reason: "") == .ageRestricted)
        #expect(M.error(code: -1, status: "UNPLAYABLE", reason: "The uploader has not made this video available in your country")
            == .unavailable(.regionLocked))
        #expect(M.error(code: -1, status: "UNPLAYABLE", reason: "Video unavailable") == .unavailable(.removed))
        #expect(M.error(code: -1, status: "ERROR", reason: "") == .unavailable(.removed))
        #expect(M.error(code: -1, status: "SOMETHING_NEW", reason: "") == .engine("playability SOMETHING_NEW"))
        #expect(QTPlaybackError.network("timeout").isNetwork && !QTPlaybackError.ageRestricted.isNetwork)
    }

    /// Without these WebKit suspends the hidden player during silent stretches (ads, gaps, test mode) and
    /// playback stalls; fail loudly if a WebKit update renames them.
    @Test func webKitStillLetsTheHiddenPlayerRun() {
        #expect(QTWebKitTuning.keepHiddenPageRunning(WKPreferences()).isEmpty)
        #expect(QTWebKitTuning.setHiddenPageThrottling(true, on: WKPreferences()).isEmpty)
    }

    @Test func malformedVideoIDsAreRejectedBeforeLoading() async {
        #expect(QTWebPlaybackEngine.isWellFormedVideoID("dQw4w9WgXcQ"))
        #expect(QTWebPlaybackEngine.isWellFormedVideoID("a-b_c123XYZ"))
        #expect(!QTWebPlaybackEngine.isWellFormedVideoID("ne3372368359"))  // mock-catalog style id
        #expect(!QTWebPlaybackEngine.isWellFormedVideoID("short"))
        #expect(!QTWebPlaybackEngine.isWellFormedVideoID("dQw4w9WgXc!"))

        let engine = QTWebPlaybackEngine(configuration: .init(isSilent: true), dataStore: .nonPersistent())
        await #expect(throws: QTPlaybackError.unavailable(.removed)) {
            try await engine.load(QTPlaybackItem(track: PB.track("ne3372368359")), autoplay: true)
        }
        #expect(engine.state.status == .failed(.unavailable(.removed)))
    }

    @Test func resolverMapsItemsToPlayableIDs() async {
        let config = QTWebPlaybackEngine.Configuration(isSilent: true, videoIDResolver: { $0.track.counterpart?.videoId ?? $0.track.videoId })
        var track = PB.track("ne1")
        track.counterpart = QTCounterpart(videoId: "wYBeTZb2a0A", musicVideoType: .omv)
        #expect(config.videoIDResolver?(QTPlaybackItem(track: track)) == "wYBeTZb2a0A")
    }

    @Test func onlyMeaningfulSamplesArePublished() {
        let item = QTPlaybackItem(track: PB.track("x"))
        let a = QTPlaybackState(item: item, status: .playing, timeline: QTPlaybackTimeline(time: 10, rate: 1, anchorUptime: 100, duration: 200),
                                duration: 200)
        var b = a
        b.timeline = QTPlaybackTimeline(time: 11.2, rate: 1, anchorUptime: 101.25, duration: 200)  // on the line (±0.05)
        #expect(!QTWebPlaybackEngine.isMeaningfulChange(from: a, to: b, at: 101.25))
        b.timeline = QTPlaybackTimeline(time: 12, rate: 1, anchorUptime: 101.25, duration: 200)    // drifted 0.75 s
        #expect(QTWebPlaybackEngine.isMeaningfulChange(from: a, to: b, at: 101.25))
        var c = a
        c.isBuffering = true
        #expect(QTWebPlaybackEngine.isMeaningfulChange(from: a, to: c, at: 100))
        var d = a
        d.ad = QTAdState(duration: 15, remaining: 14, skippableIn: nil)
        #expect(QTWebPlaybackEngine.isMeaningfulChange(from: a, to: d, at: 100))
    }

    @Test func failuresAreReportedAndSkippedOnlyWhileListening() async {
        let engine = FailingEngine(failing: ["t2"])
        let controller = QTQueueController(engine: engine)
        var events: [QTPlaybackFailureEvent] = []
        controller.onFailure = { events.append($0) }
        await controller.play(PB.tracks(3))
        await controller.next()
        #expect(controller.nowPlayingTrack?.videoId == "t3")
        #expect(events.map(\.track.videoId) == ["t2"] && events.first?.skipped == true)

        // A cued (paused) load that fails is reported but doesn't start skipping through the queue.
        events.removeAll()
        engine.failing = ["p1"]
        await controller.play([PB.track("p1"), PB.track("p2")], autoplay: false)
        #expect(controller.nowPlayingTrack?.videoId == "p1")
        #expect(events.count == 1 && events.first?.skipped == false)
    }

    @Test func givingUpIsReported() async {
        let engine = FailingEngine(failing: ["a", "b", "c"])
        let controller = QTQueueController(engine: engine)
        var events: [QTPlaybackFailureEvent] = []
        controller.onFailure = { events.append($0) }
        await controller.play([PB.track("a"), PB.track("b"), PB.track("c"), PB.track("d")])
        #expect(events.count == QTQueueController.maxConsecutiveFailures)
        #expect(events.last?.skipped == false && events.last?.consecutive == QTQueueController.maxConsecutiveFailures)
    }

    @Test func queueFlushesSynchronously() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "qt-flush-\(UUID().uuidString)/Queue.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = QTQueueStore(fileURL: url)
        let controller = QTQueueController(engine: FailingEngine(failing: []), store: store)
        controller.addToQueue([PB.track("q1")])
        controller.flushNow()
        let data = try Data(contentsOf: url)
        #expect(String(decoding: data, as: UTF8.self).contains("q1"))
    }
}
