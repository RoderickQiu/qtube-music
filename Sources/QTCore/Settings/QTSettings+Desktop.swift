import Foundation

// Settings for the window-less surfaces (mini player, desktop lyrics) and the Premium-engine playback effects.
// Added by builder "desktop"; decoded leniently like `QTSettings` so new fields never break stored data.

/// System font designs offered for desktop lyrics. Always the system font (SF Pro first in every locale;
/// PingFang SC arrives through the system cascade for Han).
public enum QTLyricsFontDesign: String, Codable, Sendable, Hashable, CaseIterable {
    case standard
    case rounded
    case serif
}

public enum QTMiniPlayerMode: String, Codable, Sendable, Hashable, CaseIterable {
    /// 340×72 strip: art · title/artist · prev/play/next.
    case compact
    /// Square artwork, controls on hover.
    case art
}

public struct QTMiniPlayerPrefs: Codable, Sendable, Hashable {
    public var mode: QTMiniPlayerMode = .compact
    /// Optional single current-lyric line at the bottom.
    public var showsLyricLine = false
    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = QTMiniPlayerPrefs()
        mode = (try? c.decodeIfPresent(QTMiniPlayerMode.self, forKey: .mode)) ?? d.mode
        showsLyricLine = (try? c.decodeIfPresent(Bool.self, forKey: .showsLyricLine)) ?? d.showsLyricLine
    }
}

public enum QTEqualizerPreset: String, Codable, Sendable, Hashable, CaseIterable {
    case off, acoustic, bassBooster, electronic, loudness, lounge, piano, rnb, spokenWord, trebleBooster, vocalBooster
}

/// Gapless, crossfade and EQ need the Premium (native) engine; free accounts play through YouTube's web player.
public struct QTPlaybackEffectsPrefs: Codable, Sendable, Hashable {
    public var gapless = true
    /// Seconds; 0 = off.
    public var crossfadeSeconds: Double = 0
    public var equalizer: QTEqualizerPreset = .off
    /// Sound Check-style loudness normalisation.
    public var normalizesVolume = false
    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = QTPlaybackEffectsPrefs()
        gapless = (try? c.decodeIfPresent(Bool.self, forKey: .gapless)) ?? d.gapless
        crossfadeSeconds = (try? c.decodeIfPresent(Double.self, forKey: .crossfadeSeconds)) ?? d.crossfadeSeconds
        equalizer = (try? c.decodeIfPresent(QTEqualizerPreset.self, forKey: .equalizer)) ?? d.equalizer
        normalizesVolume = (try? c.decodeIfPresent(Bool.self, forKey: .normalizesVolume)) ?? d.normalizesVolume
    }
}
