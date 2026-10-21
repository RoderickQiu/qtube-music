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
    /// Experimental, opt-in (off by default): Premium songs play through the native engine (QTPlayback/Native),
    /// which falls back to YouTube's player on its own when it stops working.
    public var nativeEngine = false
    public var gapless = true
    /// Seconds; 0 = off.
    public var crossfadeSeconds: Double = 0
    public var equalizer: QTEqualizerPreset = .off
    /// Sound Check-style loudness normalisation.
    public var normalizesVolume = false
    /// Playback speed of every song and video (Controls › Playback Speed), 1 = normal. Both engines play at it.
    public var playbackRate: Double = 1
    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = QTPlaybackEffectsPrefs()
        nativeEngine = (try? c.decodeIfPresent(Bool.self, forKey: .nativeEngine)) ?? d.nativeEngine
        gapless = (try? c.decodeIfPresent(Bool.self, forKey: .gapless)) ?? d.gapless
        crossfadeSeconds = (try? c.decodeIfPresent(Double.self, forKey: .crossfadeSeconds)) ?? d.crossfadeSeconds
        equalizer = (try? c.decodeIfPresent(QTEqualizerPreset.self, forKey: .equalizer)) ?? d.equalizer
        normalizesVolume = (try? c.decodeIfPresent(Bool.self, forKey: .normalizesVolume)) ?? d.normalizesVolume
        playbackRate = QTPlaybackSpeed.normalized((try? c.decodeIfPresent(Double.self, forKey: .playbackRate)) ?? d.playbackRate)
    }
}

/// Playback speed: the menus' choices, the steps of Faster / Slower, and how a speed is written. Quarter steps from
/// 0.5× to 2×: the rates YouTube's own player offers, so the web player never rounds them.
public enum QTPlaybackSpeed {
    public static let normal: Double = 1
    public static let range: ClosedRange<Double> = 0.5...2
    /// The choices, slowest first.
    public static let choices: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    /// Any speed into the supported range, on a 0.05 grid (a remote may ask for an odd value; garbage = normal).
    public static func normalized(_ rate: Double) -> Double {
        guard rate.isFinite, rate > 0 else { return normal }
        return (min(range.upperBound, max(range.lowerBound, rate)) * 20).rounded() / 20
    }

    /// The next choice up (Faster); nil at the top.
    public static func faster(than rate: Double) -> Double? { choices.first { $0 > rate + 0.001 } }

    /// The next choice down (Slower); nil at the bottom.
    public static func slower(than rate: Double) -> Double? { choices.last { $0 < rate - 0.001 } }

    public static func isNormal(_ rate: Double) -> Bool { abs(rate - normal) < 0.001 }

    /// "1.5×", "0.75×", "2×", in the interface language's number format.
    public static func label(_ rate: Double, locale: Locale = QTLoc.locale) -> String {
        rate.formatted(.number.precision(.fractionLength(0...2)).locale(locale)) + "×"
    }
}
