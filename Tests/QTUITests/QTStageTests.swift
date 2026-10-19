import QTCore
import Testing
@testable import QTUI

@Suite struct QTStageResolvedAppearanceTests {
    private func resolve(layout: QTStageLayout = .standard, background: QTStageBackground = .blur, videoMode: Bool = false,
                         hasVideo: Bool = true, hasLyrics: Bool? = true, hasVisualizerData: Bool = true,
                         isAd: Bool = false) -> QTStageResolvedAppearance {
        QTStageResolvedAppearance(layout: layout, background: background, videoMode: videoMode, hasVideo: hasVideo,
                                  hasLyrics: hasLyrics, hasVisualizerData: hasVisualizerData, isAd: isAd)
    }

    @Test func defaultsToStandardBlurWithArtwork() {
        let a = resolve()
        #expect(a.layout == .standard && a.background == .blur && !a.isVideo && a.artSlot == .artwork)
        #expect(a.selectedSwatch == .blur && !a.showsMetaUnderArt)
    }

    @Test func videoNeedsALinkedVideo() {
        #expect(resolve(videoMode: true).isVideo)
        #expect(resolve(background: .video).isVideo)
        let none = resolve(background: .video, hasVideo: false)
        #expect(!none.isVideo && none.background == .blur && none.selectedSwatch == .blur)
        #expect(resolve(videoMode: true).artSlot == .none)
    }

    @Test func visualizerNeedsSpectrumData() {
        #expect(resolve(background: .visualizer).background == .visualizer)
        let free = resolve(background: .visualizer, hasVisualizerData: false)
        #expect(free.background == .blur)
        #expect(free.selectedSwatch == .visualizer)  // the user's choice stays selected; it just can't render
    }

    @Test func tracksWithoutLyricsSwitchToArtOnly() {
        #expect(resolve(hasLyrics: false).layout == .artOnly)
        #expect(resolve(layout: .lyricsOnly, hasLyrics: false).layout == .artOnly)
        // Still loading: keep the chosen layout (no flicker).
        #expect(resolve(layout: .lyricsOnly, hasLyrics: nil).layout == .lyricsOnly)
        #expect(resolve(hasLyrics: false).showsMetaUnderArt)
    }

    @Test func coverIsTheArtInStandardLayout() {
        #expect(resolve(background: .cover).artSlot == .none)
        #expect(resolve(layout: .artOnly, background: .cover).artSlot == .artwork)
    }

    @Test func vinylPutsTheRecordInTheArtSlot() {
        let a = resolve(background: .vinyl)
        #expect(a.artSlot == .vinyl && a.background == .vinyl && a.showsMetaUnderArt)
        #expect(resolve(layout: .lyricsOnly, background: .vinyl).artSlot == .none)
    }

    @Test func adShowsBlurredArtAndTheAdCard() {
        for bg in QTStageBackground.allCases {
            let a = resolve(background: bg, isAd: true)
            #expect(a.background == .blur && a.isAd && a.artSlot == .ad, "\(bg)")
        }
    }

    @Test func motionPolicyStepsDown() {
        let normal = QTStageMotionPolicy(reduceMotion: false, lowPower: false, onBattery: false, visualizerOnBattery: false)
        #expect(normal.allowsSpin && normal.allowsAmbientDrift && normal.allowsVisualizerAnimation && normal.visualizerFPS == 60)
        let reduced = QTStageMotionPolicy(reduceMotion: true, lowPower: false, onBattery: false, visualizerOnBattery: false)
        #expect(!reduced.allowsSpin && !reduced.allowsAmbientDrift)
        let low = QTStageMotionPolicy(reduceMotion: false, lowPower: true, onBattery: false, visualizerOnBattery: false)
        #expect(low.allowsSpin && !low.allowsAmbientDrift && low.visualizerFPS == 30)
        let battery = QTStageMotionPolicy(reduceMotion: false, lowPower: false, onBattery: true, visualizerOnBattery: false)
        #expect(!battery.allowsVisualizerAnimation)
        let allowed = QTStageMotionPolicy(reduceMotion: false, lowPower: false, onBattery: true, visualizerOnBattery: true)
        #expect(allowed.allowsVisualizerAnimation)
    }

    @Test func syntheticSpectrumRestsWhenPaused() {
        // Paused: a still, clearly visible spectrum silhouette (it must still read as a visualizer), lower than play.
        let paused = QTStageVisualizerRenderer.synthetic(t: 3, playing: false)
        #expect(paused.count == QTStageVisualizerRenderer.bandCount)
        #expect(paused == QTStageVisualizerRenderer.synthetic(t: 9, playing: false))
        #expect(paused.allSatisfy { $0 > 0.01 && $0 < 0.1 } && paused.contains { $0 > 0.05 })
        let playing = QTStageVisualizerRenderer.synthetic(t: 3, playing: true)
        #expect(playing.contains { $0 > 0.12 } && playing.allSatisfy { $0 >= 0 && $0 < 0.6 })
        #expect(zip(playing, paused).allSatisfy { $0 >= $1 * 0.6 - 1e-6 })
    }

    @Test func spectrumIsMirroredAroundTheCentre() {
        for bands in [QTStageVisualizerRenderer.restingShape, QTStageVisualizerRenderer.synthetic(t: 4.2, playing: true)] {
            let n = bands.count
            #expect((0..<n / 2).allSatisfy { abs(bands[$0] - bands[n - 1 - $0]) < 1e-5 })
        }
    }

    @MainActor @Test func videoScrimsRampSmoothly() {
        let down = QTStageVideoScrims.ramp(to: 0.9, steps: 10, reversed: false)
        #expect(down.first?.location == 0 && down.last?.location == 1)
        let up = QTStageVideoScrims.ramp(to: 0.6, steps: 8, reversed: true)
        #expect(up.count == 9)
    }
}
