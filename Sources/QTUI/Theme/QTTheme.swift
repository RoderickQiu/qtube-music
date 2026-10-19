import AppKit
import QTCore
import SwiftUI

/// Design tokens. Layout numbers come from the prototype's styles.css (v2 spacing pass); colours, materials and
/// fonts map onto macOS system semantics so the app looks native in light, dark, Increase Contrast and Reduce
/// Transparency. The artwork accent is only ever a *tint* — never a replacement for system chrome.
public enum QTTheme {
    // MARK: Spacing (4 / 8 / 12 / 16 / 24 / 32, + 44 page gutter)

    public enum Spacing {
        public static let xxs: CGFloat = 4
        public static let xs: CGFloat = 8
        public static let s: CGFloat = 12
        public static let m: CGFloat = 16
        public static let l: CGFloat = 24
        public static let xl: CGFloat = 32
        /// Page gutter for Home / Library content (`.lib-head`, `.shelf header`).
        public static let gutter: CGFloat = 44
        /// Gap between cards in a shelf row.
        public static let shelfGap: CGFloat = 20
        /// Vertical gap between Home shelves.
        public static let shelfSpacing: CGFloat = 36
    }

    // MARK: Radii

    public enum Radius {
        /// Small controls, rows, chips' inner elements.
        public static let control: CGFloat = 6
        /// Artwork thumbnails and cards.
        public static let artwork: CGFloat = 8
        /// Large artwork (panel hero, playlist tile, Stage art).
        public static let artworkLarge: CGFloat = 10
        /// Floating surfaces drawn by us (toast, queue drawer). System popovers/menus keep their own radius.
        public static let floating: CGFloat = 14
        public static let drawer: CGFloat = 16
        /// The floating player bar (concentric with the window corner at a 10 pt inset) and the Stage transport.
        public static let playerBar: CGFloat = 22
    }

    // MARK: Metrics

    public enum Metrics {
        public static let sidebarWidth: CGFloat = 248
        public static let sidebarMinWidth: CGFloat = 200
        public static let panelWidth: CGFloat = 384
        public static let panelMinWidth: CGFloat = 320
        public static let panelMaxWidth: CGFloat = 480
        public static let playerBarHeight: CGFloat = 72
        /// Gap between the floating player bar and the window edges.
        public static let playerBarInset: CGFloat = 10
        public static let playerBarSideWidth: CGFloat = 320
        public static let scrubberMaxWidth: CGFloat = 560
        public static let tableRowHeight: CGFloat = 60
        public static let rowArtwork: CGFloat = 40
        public static let playerBarArtwork: CGFloat = 48
        public static let panelHeroArtwork: CGFloat = 88
        public static let panelHeroHeight: CGFloat = 128
        public static let playlistTile: CGFloat = 148
        public static let card: CGFloat = 172
        public static let videoCardWidth: CGFloat = 304
        public static let videoCardHeight: CGFloat = 171
        public static let quickPickArtwork: CGFloat = 52
        public static let stageArtwork: CGFloat = 440
        public static let stageArtworkArtOnly: CGFloat = 480
        public static let stageInset: CGFloat = 64
        public static let stageTopBarHeight: CGFloat = 72
        public static let stageQueueWidth: CGFloat = 372
        public static let miniCompact = CGSize(width: 340, height: 72)
        public static let miniArt = CGSize(width: 300, height: 300)
        public static let defaultWindow = CGSize(width: 1440, height: 900)
    }

    // MARK: Typography — system text styles (SF Pro; PingFang SC arrives via the system cascade for Han).
    // Never name a CJK font first; never force uppercase/tracking on CJK.

    public enum Typography {
        /// 13 pt body (`body` in the prototype).
        public static let body = Font.body
        /// 12 pt secondary rows / subtitles.
        public static let secondary = Font.callout
        /// 11 pt section headers, badges, scrubber times.
        public static let caption = Font.subheadline
        /// 13 pt semibold row titles.
        public static let rowTitle = Font.body.weight(.medium)
        /// Panel hero title (16–19 pt in the prototype).
        public static let panelTitle = Font.title3.weight(.semibold)
        /// Home shelf titles (20 pt bold).
        public static let shelfTitle = Font.title2.bold()
        /// Page titles: greeting, "Liked Songs" (28–30 pt bold).
        public static let pageTitle = Font.largeTitle.bold()
        /// Stage title (26 pt bold) and its subtitle (15 pt).
        public static let stageTitle = Font.system(size: 26, weight: .bold)
        public static let stageSubtitle = Font.title3

        /// Lyric line sizes per surface: (current/main line, translation line), from styles.css.
        public static func lyricSizes(_ surface: LyricSurface) -> (main: CGFloat, translation: CGFloat) {
            switch surface {
            case .panel: (19, 14)
            case .stage: (34, 22)
            case .mini: (13, 12)
            case .desktop: (36, 20)
            case .videoOverlay: (40, 22)
            case .artOnly: (22, 15)
            }
        }

        public enum LyricSurface: Sendable { case panel, stage, mini, desktop, videoOverlay, artOnly }

        public static func lyric(_ surface: LyricSurface) -> Font {
            .system(size: lyricSizes(surface).main, weight: .bold)
        }

        public static func lyricTranslation(_ surface: LyricSurface) -> Font {
            .system(size: lyricSizes(surface).translation, weight: surface == .panel ? .medium : .semibold)
        }
    }

    // MARK: Colour — system semantics + one artwork accent

    public enum Colors {
        public static let label = Color(nsColor: .labelColor)
        public static let secondaryLabel = Color(nsColor: .secondaryLabelColor)
        public static let tertiaryLabel = Color(nsColor: .tertiaryLabelColor)
        public static let quaternaryLabel = Color(nsColor: .quaternaryLabelColor)
        public static let separator = Color(nsColor: .separatorColor)
        public static let windowBackground = Color(nsColor: .windowBackgroundColor)
        public static let contentBackground = Color(nsColor: .textBackgroundColor)
        public static let controlBackground = Color(nsColor: .controlBackgroundColor)
        public static let selection = Color(nsColor: .selectedContentBackgroundColor)
        public static let unemphasizedSelection = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
        /// Subtle fills (chips, placeholders).
        public static let fill = Color(nsColor: .quaternarySystemFill)
        public static let systemAccent = Color(nsColor: .controlAccentColor)

        /// Content drawn over artwork on the Stage / mini player (always dark context).
        public static let onArt = Color.white
        public static let onArtSecondary = Color.white.opacity(0.62)
        public static let onArtTertiary = Color.white.opacity(0.34)

        /// The artwork accent normalised for legibility (oklch L .74 on dark, .56 on light). Falls back to the
        /// system accent when there is no artwork or when Increase Contrast is on.
        public static func accent(_ palette: QTArtworkPalette?, scheme: ColorScheme, increaseContrast: Bool = false) -> Color {
            guard let palette, !increaseContrast else { return systemAccent }
            return Color(qt: scheme == .dark ? palette.accentOnDark : palette.accentOnLight)
        }

        /// Base colour behind the Stage's blurred art.
        public static func stageBase(_ palette: QTArtworkPalette?) -> Color {
            palette.map { Color(qt: $0.deep) } ?? Color(nsColor: .black)
        }
    }

    // MARK: Motion — one curve: cubic-bezier(.2, .8, .2, 1); 320 ms UI, 520 ms lyric scroll

    public enum Motion {
        public static let uiDuration: TimeInterval = 0.32
        public static let lyricDuration: TimeInterval = 0.52
        public static let chromeFadeDuration: TimeInterval = 0.6
        /// Stage chrome hides after this long without mouse movement while playing.
        public static let chromeIdleDelay: TimeInterval = 3

        public static let ui = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: uiDuration)
        public static let lyricScroll = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: lyricDuration)
        public static let chromeFade = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: chromeFadeDuration)
        /// Springs for panel slides, lyric scroll, tonearm.
        public static let spring = Animation.spring(response: 0.32, dampingFraction: 0.86)
        public static let lyricSpring = Animation.spring(response: 0.52, dampingFraction: 0.84)
        public static let gentleSpring = Animation.spring(response: 0.9, dampingFraction: 0.8)

        /// Core Animation equivalent of the curve, for layer-backed renderers.
        public static var caTimingFunction: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1) }

        /// Respect Reduce Motion: swap movement for a short cross-fade.
        public static func animation(_ animation: Animation, reduceMotion: Bool) -> Animation {
            reduceMotion ? .easeInOut(duration: 0.15) : animation
        }
    }
}

public extension Color {
    init(qt c: QTRGBColor) {
        self.init(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: 1)
    }
}

// MARK: - Accent environment

private struct QTAccentKey: EnvironmentKey {
    static let defaultValue: Color = QTTheme.Colors.systemAccent
}

public extension EnvironmentValues {
    /// The artwork-driven accent for the current track — a light tint only (progress, now-playing marks, washes).
    /// In the main window `.tint` is the system accent (`qtArtworkAccent`); over art it's this too (`qtArtworkTint`).
    var qtAccent: Color {
        get { self[QTAccentKey.self] }
        set { self[QTAccentKey.self] = newValue }
    }
}

/// Applies the artwork accent as tint + `qtAccent` environment, recomputed for light/dark/Increase Contrast.
public struct QTArtworkTint: ViewModifier {
    let palette: QTArtworkPalette?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    public func body(content: Content) -> some View {
        let accent = QTTheme.Colors.accent(palette, scheme: scheme, increaseContrast: contrast == .increased)
        content
            .tint(accent)
            .environment(\.qtAccent, accent)
    }
}

/// The artwork accent as `\.qtAccent` only — `.tint` stays the system accent. The main window's policy: system accent
/// for selection and system controls (sidebar, table selection, Play, toggles, menus); the artwork accent only as a
/// light tint read from `\.qtAccent` (scrubber progress, now-playing marks, panel wash).
public struct QTArtworkAccent: ViewModifier {
    let palette: QTArtworkPalette?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    public func body(content: Content) -> some View {
        content.environment(\.qtAccent, QTTheme.Colors.accent(palette, scheme: scheme, increaseContrast: contrast == .increased))
    }
}

public extension View {
    /// Artwork accent as `.tint` *and* `\.qtAccent`: for surfaces drawn over the artwork (Stage, mini player, menu
    /// bar popover), where the system accent would clash with the art. Browsing chrome uses `qtArtworkAccent`.
    func qtArtworkTint(_ palette: QTArtworkPalette?) -> some View {
        modifier(QTArtworkTint(palette: palette))
    }

    /// Artwork accent as `\.qtAccent` only (the main window): `.tint` stays the system accent.
    func qtArtworkAccent(_ palette: QTArtworkPalette?) -> some View {
        modifier(QTArtworkAccent(palette: palette))
    }

    /// Floating surface (kept for existing callers): the `.chrome` glass primitive (`QTGlass.swift`). `material`
    /// is ignored — the primitive picks the macOS 15 material and the Reduce Transparency solid in one place.
    func qtFloatingSurface<S: Shape>(_ shape: S, material: Material = .regularMaterial) -> some View {
        qtGlass(.chrome, in: shape)
    }
}
