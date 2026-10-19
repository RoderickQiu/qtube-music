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
                QTLyricsUnavailableView(kind: unavailableKind, style: style)
                    // Re-opening the lyrics for the same track retries a lookup that couldn't reach the sources.
                    .onAppear { model?.lyricsSession?.retryIfUnreachable() }
            }
        }
        .modifier(QTLyricsTranslationHost(document: document, key: showsTranslation ? resolution.machineKey : nil))
    }

    @ViewBuilder
    private func content(_ doc: QTLyricsDocument, resolution: QTLyricsTranslationResolution) -> some View {
        let lanes = lanes(resolution)
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
                        .padding(.bottom, bottomClearance)
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                } else if style == .panel, showsTranslation, case .needsDownload(let code) = resolution.status,
                          let key = resolution.machineKey {
                    // The translation waits for a language download only the user can agree to: one quiet cue
                    // (the options popover has the same consent row).
                    QTLyricsTranslationCue(language: code) { QTLyricsTranslationCenter.shared.requestDownload(key) }
                        .padding(.bottom, bottomClearance)
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
            }
            .animation(QTTheme.Motion.animation(QTTheme.Motion.spring, reduceMotion: reduceMotion), value: controller.isDetached)
            .animation(QTTheme.Motion.animation(QTTheme.Motion.ui, reduceMotion: reduceMotion), value: resolution.status)
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

    /// Room under the floating buttons. The docked panel runs under the window's floating player bar (an inspector
    /// column gets no safe-area inset from it), so they sit above the bar there.
    private var bottomClearance: CGFloat {
        guard style == .panel else { return 18 }
        return QTTheme.Metrics.playerBarHeight + QTTheme.Metrics.playerBarInset + 4 + 14
    }

    /// Translation lane (unless this surface hides it) and the pronunciation lane (pinyin…): the user's choice;
    /// Automatic shows it only without a translation line.
    private func lanes(_ resolution: QTLyricsTranslationResolution) -> QTLyricsLanes {
        var lanes = showsTranslation ? resolution.lanes : QTLyricsLanes(translations: nil, translationLanguage: nil)
        let pronunciation = model?.settings.settings.lyricsPronunciation ?? .automatic
        lanes.showsRomanization = pronunciation.shows(withTranslation: showsTranslation && resolution.expectsTranslation)
        return lanes
    }

    /// Instrumental, no lyrics, or no lyrics *yet* because the sources couldn't be reached (offline).
    private var unavailableKind: QTLyricsUnavailableView.Kind {
        if let document, QTLyricsRowBuilder.isInstrumental(document) { return .instrumental }
        if document == nil, let session = model?.lyricsSession, session.phase == .unreachable {
            return session.isNetworkAvailable ? .unreachable : .offline
        }
        return .none
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

/// "Translate to English": the panel's quiet cue when the translation line waits for a language download. Clicking
/// asks the system (its own consent sheet) to download the model; nothing downloads without it.
struct QTLyricsTranslationCue: View {
    let language: String
    let action: () -> Void

    var body: some View {
        let name = QTLyricsTranslationTarget.nativeName(for: language)
        Button(action: action) {
            Label(QTLoc.tr("Translate to %@", table: .lyrics, name), systemImage: "translate")
                .font(.callout)
                .labelStyle(.titleAndIcon)
                .padding(.leading, 11)
                .padding(.trailing, 14)
                .frame(height: 28)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .qtGlass(.chrome, in: Capsule(), interactive: true)
        .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
        .help(QTLoc.tr("Download %@ for offline translation", name))
        .accessibilityHint(QTLoc.tr("Download %@ for offline translation", name))
        .accessibilityIdentifier("qt.lyrics.translationCue")
    }
}

/// No lyrics / instrumental / offline: a symbol and a word, nothing explanatory. Offline lyrics come back by
/// themselves when the network does (`QTLyricsSession.networkDidChange`).
struct QTLyricsUnavailableView: View {
    enum Kind: Equatable {
        case none
        case instrumental
        /// The Mac is offline; the lookup retries on reconnect.
        case offline
        /// Online, but the lyric sources didn't answer: a quiet Try Again.
        case unreachable
    }

    let kind: Kind
    let style: QTLyricsStyle
    @Environment(QTAppModel.self) private var model: QTAppModel?

    init(kind: Kind, style: QTLyricsStyle) {
        self.kind = kind
        self.style = style
    }

    init(isInstrumental: Bool, style: QTLyricsStyle) {
        self.init(kind: isInstrumental ? .instrumental : .none, style: style)
    }

    var body: some View {
        VStack(spacing: style == .panel ? 10 : 14) {
            Image(systemName: symbol)
                .font(.system(size: style == .panel ? 26 : 40, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .contentTransition(.symbolEffect(.replace))
            Text(title)
                .font(style == .panel ? .title3.weight(.semibold) : .title.weight(.semibold))
            if kind == .unreachable {
                Button(QTLoc.tr("Try Again", table: .lyrics)) {
                    model?.lyricsSession?.retryIfUnreachable(force: true)
                }
                .buttonStyle(.borderless)
                .controlSize(style == .panel ? .small : .regular)
                .foregroundStyle(style.isOverArt ? AnyShapeStyle(QTTheme.Colors.onArtSecondary) : AnyShapeStyle(.secondary))
                .padding(.top, 2)
                .accessibilityIdentifier("qt.lyrics.retry")
            }
        }
        .foregroundStyle(style.isOverArt ? AnyShapeStyle(QTTheme.Colors.onArtTertiary) : AnyShapeStyle(.tertiary))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: style.isCentered || style == .panel ? .center : .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private var symbol: String {
        switch kind {
        case .none: "quote.bubble"
        case .instrumental: "music.note"
        case .offline: "wifi.slash"
        case .unreachable: "icloud.slash"
        }
    }

    private var title: String {
        switch kind {
        case .none: QTLoc.tr("No lyrics")
        case .instrumental: QTLoc.tr("Instrumental")
        case .offline: QTLoc.tr("Offline", table: .lyrics)
        case .unreachable: QTLoc.tr("Can’t reach lyrics", table: .lyrics)
        }
    }

    private var identifier: String {
        switch kind {
        case .none: "qt.lyrics.none"
        case .instrumental: "qt.lyrics.instrumental"
        case .offline: "qt.lyrics.offline"
        case .unreachable: "qt.lyrics.unreachable"
        }
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

extension QTLyricsLaneLevel {
    /// SwiftUI surfaces: the lane's opacity relative to its lyric's style (`.primary`, white over art…).
    static func current(_ contrast: ColorSchemeContrast) -> Double { Double(current(increaseContrast: contrast == .increased)) }
    /// The lane under a dimmed (upcoming) line, relative to that line's style.
    static func inactive(_ contrast: ColorSchemeContrast) -> Double { Double(inactive(increaseContrast: contrast == .increased)) }
}
