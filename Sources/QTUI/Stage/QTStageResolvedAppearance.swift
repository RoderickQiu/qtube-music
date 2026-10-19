import QTCore

/// What the Stage actually shows, resolved from the user's choices and the current track/account/ad state.
/// Pure value logic (unit-tested) so the view code stays declarative.
///
/// Rules (prototype stage.jsx + spec §4.1):
/// - Video shows when the user picked Video (pill or swatch) *and* the track has a linked music video.
/// - A stored "video" background on a track without a video falls back to blurred art.
/// - The visualizer needs the Premium engine; free accounts fall back to blurred art.
/// - Tracks without lyrics switch to Art only automatically (not while lyrics are still loading).
/// - Full-bleed cover in the Standard layout has no art tile: the cover *is* the background.
/// - During an ad the song's art is shown blurred and dimmed, and the art slot holds the ad card.
public struct QTStageResolvedAppearance: Equatable, Sendable {
    public enum ArtSlot: Equatable, Sendable {
        /// Square artwork tile.
        case artwork
        /// Spinning record with the cover as its label.
        case vinyl
        /// The ad card (blurred, dimmed song art + countdown).
        case ad
        /// Nothing in the art column.
        case none
    }

    public var layout: QTStageLayout
    public var background: QTStageBackground
    /// The music-video presentation (video background + synced-lyric overlay) replaces the layout.
    public var isVideo: Bool
    public var artSlot: ArtSlot
    /// Background is the song's art blurred and dimmed for an ad.
    public var isDimmedForAd: Bool
    /// Selected background swatch in the Appearance popover (`video` while the video shows).
    public var selectedSwatch: QTStageBackground

    public init(layout: QTStageLayout, background: QTStageBackground, videoMode: Bool, hasVideo: Bool,
                hasLyrics: Bool?, isPremium: Bool, isAd: Bool) {
        let isVideo = (videoMode || background == .video) && hasVideo
        var bg: QTStageBackground = isVideo ? .video : (background == .video ? .blur : background)
        if bg == .visualizer && !isPremium { bg = .blur }
        if isAd { bg = .blur }
        let layout: QTStageLayout = hasLyrics == false ? .artOnly : layout

        let art: ArtSlot
        if isAd {
            art = .ad
        } else if layout == .lyricsOnly || isVideo {
            art = .none
        } else if bg == .vinyl {
            art = .vinyl
        } else if bg == .cover && layout == .standard {
            art = .none
        } else {
            art = .artwork
        }

        self.layout = layout
        self.background = bg
        self.isVideo = isVideo
        self.artSlot = art
        self.isDimmedForAd = isAd
        self.selectedSwatch = isVideo ? .video : (background == .video ? .blur : background)
    }

    /// Title/artist sit under the art (centred) for Art only and for the vinyl record; otherwise above the lyrics.
    public var showsMetaUnderArt: Bool {
        !isVideo && (layout == .artOnly || (artSlot == .vinyl && layout == .standard))
    }
}
