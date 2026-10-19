import QTCore
import Testing
@testable import QTUI

@Suite struct QTStageResolvedAppearanceTests {
    private func resolve(layout: QTStageLayout = .standard, background: QTStageBackground = .blur, videoMode: Bool = false,
                         hasVideo: Bool = true, hasLyrics: Bool? = true, isPremium: Bool = true,
                         isAd: Bool = false) -> QTStageResolvedAppearance {
        QTStageResolvedAppearance(layout: layout, background: background, videoMode: videoMode, hasVideo: hasVideo,
                                  hasLyrics: hasLyrics, isPremium: isPremium, isAd: isAd)
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

    @Test func visualizerIsPremiumOnly() {
        #expect(resolve(background: .visualizer).background == .visualizer)
        let free = resolve(background: .visualizer, isPremium: false)
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

    @Test func adShowsBlurredDimmedArtAndTheAdCard() {
        for bg in QTStageBackground.allCases {
            let a = resolve(background: bg, isAd: true)
            #expect(a.background == .blur && a.isDimmedForAd && a.artSlot == .ad, "\(bg)")
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
        let paused = QTStageVisualizerRenderer.synthetic(t: 3, playing: false)
        #expect(paused.count == QTStageVisualizerRenderer.bandCount && paused.allSatisfy { $0 < 0.02 })
        let playing = QTStageVisualizerRenderer.synthetic(t: 3, playing: true)
        #expect(playing.contains { $0 > 0.05 } && playing.allSatisfy { $0 >= 0 && $0 < 0.6 })
    }
}
