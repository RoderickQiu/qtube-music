import AppKit
import QTCore
import SwiftUI

/// User-chosen lyric typography for the single-line surfaces (desktop lyrics overlay). Set by the desktop builder
/// with `.environment(\.qtLyricsFontOverride, …)`; `QTLyricsView` uses it for `.desktop` / `.mini` when present.
/// Always the system font (SF Pro first in every locale; Han falls back to PingFang SC through the system cascade).
public struct QTLyricsFontOverride: Hashable, Sendable {
    /// Point size of the main line; the translation line is ~56 % of it.
    public var mainSize: CGFloat
    public var design: QTLyricsFontDesign

    public init(mainSize: CGFloat, design: QTLyricsFontDesign = .standard) {
        self.mainSize = mainSize
        self.design = design
    }

    public var translationSize: CGFloat { (mainSize * 0.56).rounded() }

    public var fontDesign: Font.Design {
        switch design {
        case .standard: .default
        case .rounded: .rounded
        case .serif: .serif
        }
    }

    public var main: Font { .system(size: mainSize, weight: .bold, design: fontDesign) }
    public var translation: Font { .system(size: translationSize, weight: .semibold, design: fontDesign) }
}

private struct QTLyricsFontOverrideKey: EnvironmentKey {
    static let defaultValue: QTLyricsFontOverride? = nil
}

public extension EnvironmentValues {
    var qtLyricsFontOverride: QTLyricsFontOverride? {
        get { self[QTLyricsFontOverrideKey.self] }
        set { self[QTLyricsFontOverrideKey.self] = newValue }
    }
}

public extension QTLyricsFontDesign {
    /// The AppKit system design (Core Text lyric renderer).
    var systemDesign: NSFontDescriptor.SystemDesign {
        switch self {
        case .standard: .default
        case .rounded: .rounded
        case .serif: .serif
        }
    }
}
