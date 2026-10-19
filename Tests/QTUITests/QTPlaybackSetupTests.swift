import Foundation
import QTCore
import QTPlayback
import Testing
@testable import QTUI

/// Engine wiring: mock data never takes the media keys, plays silently and never persists the queue unless asked.
@MainActor
@Suite struct QTPlaybackSetupTests {
    private func launch(_ args: [String: String]) -> QTLaunchOptions { QTLaunchOptions(arguments: args) }

    @Test func mockDataDefaultsToTheSimulatedEngine() {
        let s = QTPlaybackSetup.resolve(launch: launch([:]), source: .mock, tier: .premium)
        #expect(s.engine == .simulated && !s.publishesNowPlaying && !s.persistsQueue && s.isAnonymous)
    }

    @Test func mockDataThroughTheWebEngineIsSilentAndAnonymous() {
        let s = QTPlaybackSetup.resolve(launch: launch(["qt.engine": "web"]), source: .mock, tier: .free)
        #expect(s.engine == .web && s.isSilent && s.isAnonymous && s.publishesNowPlaying && !s.persistsQueue)
        let loud = QTPlaybackSetup.resolve(launch: launch(["qt.engine": "web", "qt.playback.silent": "NO"]), source: .mock, tier: .free)
        #expect(!loud.isSilent)
    }

    @Test func realDataUsesTheWebEngineForEveryTierUntilNativeShips() {
        for tier in [QTPlaybackAccountTier.free, .premium] {
            let s = QTPlaybackSetup.resolve(launch: launch([:]), source: .live, tier: tier)
            // Signed in by default (approved): the player page uses the session (Premium plays without ads).
            #expect(s.engine == .web && !s.isSilent && !s.isAnonymous && s.publishesNowPlaying && s.persistsQueue)
        }
        let anonymous = QTPlaybackSetup.resolve(launch: launch(["qt.playback.anonymous": "YES"]), source: .live, tier: .premium)
        #expect(anonymous.isAnonymous)
        // Real ids play as they are; demo ids (switching to the demo library mid-session) map to their MV.
        var real = QTTrack(videoId: "dQw4w9WgXcQ", title: "T", artists: [], duration: 200)
        real.counterpart = QTCounterpart(videoId: "wYBeTZb2a0A", musicVideoType: .omv)
        #expect(QTPlaybackSetup.liveVideoID(for: QTPlaybackItem(track: real, mode: .song)) == "dQw4w9WgXcQ")
        var demo = QTTrack(videoId: "ne34516548", title: "T", artists: [], duration: 200)
        demo.counterpart = QTCounterpart(videoId: "wYBeTZb2a0A", musicVideoType: .omv)
        #expect(QTPlaybackSetup.liveVideoID(for: QTPlaybackItem(track: demo, mode: .song)) == "wYBeTZb2a0A")
        // Scripted runs (screenshots) never overwrite the saved queue and stay silent.
        let shot = QTPlaybackSetup.resolve(launch: launch(["qt.readyFile": "/tmp/x"]), source: .live, tier: .free)
        #expect(!shot.persistsQueue && shot.isSilent)
    }

    @Test func mockTracksPlayTheirMusicVideo() {
        var track = QTTrack(videoId: "ne34516548", title: "T", artists: [], duration: 200)
        track.counterpart = QTCounterpart(videoId: "wYBeTZb2a0A", musicVideoType: .omv)
        #expect(QTPlaybackSetup.mockVideoID(for: QTPlaybackItem(track: track, mode: .song)) == "wYBeTZb2a0A")
        #expect(QTPlaybackSetup.mockVideoID(for: QTPlaybackItem(track: track, mode: .video)) == "wYBeTZb2a0A")
        let noVideo = QTTrack(videoId: "ne3372368359", title: "T", artists: [], duration: 200)
        #expect(QTPlaybackSetup.mockVideoID(for: QTPlaybackItem(track: noVideo)) == "ne3372368359")
    }

    @Test func failureToastsAreLocalized() {
        let track = QTTrack(videoId: "x", title: "Song", artists: [], duration: 1)
        let skipped = QTPlaybackFailureEvent(track: track, error: .ageRestricted, skipped: true, consecutive: 1)
        #expect(QTPlaybackServices.message(for: skipped).contains("Song"))
        let gaveUp = QTPlaybackFailureEvent(track: track, error: .unavailable(.removed), skipped: false, consecutive: 3)
        #expect(!QTPlaybackServices.message(for: gaveUp).contains("Song"))
    }
}
