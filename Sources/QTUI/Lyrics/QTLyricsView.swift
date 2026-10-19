import AppKit
import QTCore
import QTPlayback
import SwiftUI

// Owner: builder "lyrics-ui". The public signature below is the shared contract (used by NowPlaying, Stage,
// Desktop). Rendering is AppKit + Core Animation (`QTLyricsRailView`, `QTLyricsFocusView`); this file is the
// SwiftUI front: style, translation lane, empty/instrumental states and the "Current" jump-back pill.

/// Where a lyrics view is shown; each has its own type size, alignment and colour context.
public enum QTLyricsStyle: Hashable, Sendable {
    /// Docked panel: left-aligned, 19/14 pt, system label colours.
    case panel
    /// Stage: 34/22 pt over art (white), leading or centred (Lyrics-only layout).
    case stage(centered: Bool)
    /// Mini player / menu bar: the current line only, system label colours.
    case mini
    /// Desktop lyrics overlay: one or two big lines with shadow + outline, click-through.
    case desktop

    var surface: QTTheme.Typography.LyricSurface {
        switch self {
        case .panel: .panel
        case .stage: .stage
        case .mini: .mini
        case .desktop: .desktop
        }
    }

    var isOverArt: Bool {
        switch self {
        case .stage, .desktop: true
        case .panel, .mini: false
        }
    }

    var isCentered: Bool {
        switch self {
        case .stage(let c): c
        case .desktop: true
        default: false
        }
    }

    var isScrolling: Bool {
        switch self {
        case .panel, .stage: true
        case .mini, .desktop: false
        }
    }
}

/// Synced lyrics. `time` is the playback timeline (anchor + rate) so the view schedules its own animations;
/// the parent only re-renders on play/pause/seek. `onSeek` receives a playback time.
///
/// Reads `QTAppModel` / `QTPlayerModel` from the environment when present (translation target, ads, loading);
/// works without them (previews, tests).
public struct QTLyricsView: View {
    private let document: QTLyricsDocument?
    private let time: QTPlaybackTimeline
    private let style: QTLyricsStyle
    private let showsTranslation: Bool
    private let desktopLineCount: Int
    private let desktopFontSize: CGFloat?
    private let onSeek: (TimeInterval) -> Void
    @Environment(\.qtLyricsFontOverride) private var fontOverride

    @Environment(QTAppModel.self) private var model: QTAppModel?
    @Environment(QTPlayerModel.self) private var player: QTPlayerModel?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var controller = QTLyricsRailController()

    /// - Parameters:
    ///   - desktopLineCount: `.desktop` only — 1 (current line) or 2 (current + translation, or + next line).
    ///   - desktopFontSize: `.desktop` only — main line size in points (Settings › Desktop Lyrics).
    public init(document: QTLyricsDocument?, time: QTPlaybackTimeline, style: QTLyricsStyle,
                showsTranslation: Bool = true, desktopLineCount: Int = 2, desktopFontSize: CGFloat? = nil,
                onSeek: @escaping (TimeInterval) -> Void) {
        self.document = document
        self.time = time
        self.style = style
        self.showsTranslation = showsTranslation
        self.desktopLineCount = desktopLineCount
        self.desktopFontSize = desktopFontSize
        self.onSeek = onSeek
    }

    public var body: some View {
        let resolution = translation
        Group {
            if let document, !document.lines.isEmpty, !QTLyricsRowBuilder.isInstrumental(document) {
                content(document, resolution: resolution)
            } else if player?.isLoadingLyrics == true || !style.isScrolling {
                Color.clear
            } else {
                QTLyricsUnavailableView(isInstrumental: document.map(QTLyricsRowBuilder.isInstrumental) ?? false, style: style)
            }
        }
        .modifier(QTLyricsTranslationHost(document: document, key: showsTranslation ? resolution.machineKey : nil))
    }

    @ViewBuilder
    private func content(_ doc: QTLyricsDocument, resolution: QTLyricsTranslationResolution) -> some View {
        let lanes = showsTranslation ? resolution.lanes : QTLyricsLanes(translations: nil, translationLanguage: nil)
        let clock = QTLyricsClock(timeline: time, offset: doc.offset, stalled: isStalled)
        if style.isScrolling {
            ZStack(alignment: .bottom) {
                QTLyricsRailRepresentable(
                    configuration: QTLyricsRailConfiguration(
                        document: doc, lanes: lanes, clock: clock, style: style, textScale: textScale,
                        increaseContrast: contrast == .increased, reduceMotion: reduceMotion,
                        startsScrolled: model?.launch.bool("qt.lyrics.scrolled") == true),
                    controller: controller, onSeek: onSeek)
                if controller.isDetached {
                    QTLyricsCurrentPill(controller: controller, overArt: style.isOverArt)
                        .padding(.bottom, 18)
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
            }
            .animation(QTTheme.Motion.animation(QTTheme.Motion.spring, reduceMotion: reduceMotion), value: controller.isDetached)
        } else {
            QTLyricsFocusRepresentable(configuration: QTLyricsFocusConfiguration(
                document: doc, lanes: lanes, clock: clock, style: style, textScale: textScale,
                increaseContrast: contrast == .increased, reduceMotion: reduceMotion,
                lineCount: desktopLineCount,
                // An explicit size wins; otherwise the desktop overlay's \.qtLyricsFontOverride (Settings).
                desktopFontSize: desktopFontSize ?? fontOverride?.mainSize,
                fontDesign: fontOverride?.design ?? .standard))
        }
    }

    /// Lyrics stand still while an ad plays.
    private var isStalled: Bool { player?.ad != nil }

    /// Same resolution as `QTAppModel.resolvedLyrics` (every surface shows the same lane).
    private var translation: QTLyricsTranslationResolution {
        let center = QTLyricsTranslationCenter.shared
        guard let model else { return center.resolve(document, target: nil, honorsTarget: false) }
        return center.resolve(document, target: model.resolvedTranslationLanguage)
    }

    /// Dynamic Type for lyrics (draft §8): scales every lyric size together.
    private var textScale: CGFloat {
        switch dynamicTypeSize {
        case .xSmall: 0.85
        case .small: 0.92
        case .medium: 0.96
        case .large: 1
        case .xLarge: 1.08
        case .xxLarge: 1.16
        case .xxxLarge: 1.24
        default: 1.32
        }
    }
}

// MARK: - Pieces

/// Floating "Current" button shown after scrolling away; returns to the line being sung.
struct QTLyricsCurrentPill: View {
    let controller: QTLyricsRailController
    let overArt: Bool

    var body: some View {
        Button {
            controller.returnToCurrent()
        } label: {
            Label(QTLoc.tr("Current"), systemImage: controller.currentIsBelow ? "chevron.down" : "chevron.up")
                .font(.callout.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .padding(.leading, 11)
                .padding(.trailing, 14)
                .frame(height: 30)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .qtGlass(overArt ? .overArt : .chrome, in: Capsule(), interactive: true)
        .shadow(color: .black.opacity(overArt ? 0.3 : 0.14), radius: 14, y: 5)
        .help(QTLoc.tr("Back to the current line"))
        .accessibilityLabel(QTLoc.tr("Back to the current line"))
        .accessibilityIdentifier("qt.lyrics.currentPill")
    }
}

/// No lyrics / instrumental: a symbol and a word, nothing explanatory.
struct QTLyricsUnavailableView: View {
    let isInstrumental: Bool
    let style: QTLyricsStyle

    var body: some View {
        VStack(spacing: style == .panel ? 10 : 14) {
            Image(systemName: isInstrumental ? "music.note" : "quote.bubble")
                .font(.system(size: style == .panel ? 26 : 40, weight: .regular))
                .symbolRenderingMode(.hierarchical)
            Text(QTLoc.tr(isInstrumental ? "Instrumental" : "No lyrics"))
                .font(style == .panel ? .title3.weight(.semibold) : .title.weight(.semibold))
        }
        .foregroundStyle(style.isOverArt ? AnyShapeStyle(QTTheme.Colors.onArtTertiary) : AnyShapeStyle(.tertiary))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: style.isCentered || style == .panel ? .center : .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(isInstrumental ? "qt.lyrics.instrumental" : "qt.lyrics.none")
    }
}

struct QTLyricsRailRepresentable: NSViewRepresentable {
    let configuration: QTLyricsRailConfiguration
    let controller: QTLyricsRailController
    let onSeek: (TimeInterval) -> Void

    func makeNSView(context: Context) -> QTLyricsRailView {
        let view = QTLyricsRailView(frame: .zero)
        view.controller = controller
        controller.rail = view
        return view
    }

    func updateNSView(_ view: QTLyricsRailView, context: Context) {
        view.onSeek = onSeek
        view.controller = controller
        controller.rail = view
        view.apply(configuration)
    }
}

struct QTLyricsFocusRepresentable: NSViewRepresentable {
    let configuration: QTLyricsFocusConfiguration

    func makeNSView(context: Context) -> QTLyricsFocusView { QTLyricsFocusView(frame: .zero) }

    func updateNSView(_ view: QTLyricsFocusView, context: Context) {
        view.apply(configuration)
    }
}
