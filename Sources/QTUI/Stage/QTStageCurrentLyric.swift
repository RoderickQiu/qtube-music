import QTCore
import QTPlayback
import SwiftUI

/// The single current lyric line (+ translation) used where a full lyrics column doesn't fit: over the music
/// video and under the art in Art only. Word-synced lines fill word by word. Interpolates the timeline itself,
/// so the parent only re-renders on play/pause/seek.
struct QTStageCurrentLyric: View {
    enum Style { case videoOverlay, artOnly }

    let document: QTLyricsDocument?
    let time: QTPlaybackTimeline
    let style: Style
    let showsTranslation: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(QTAppModel.self) private var model: QTAppModel?

    private var surface: QTTheme.Typography.LyricSurface { style == .videoOverlay ? .videoOverlay : .artOnly }
    private var alignment: HorizontalAlignment { style == .videoOverlay ? .leading : .center }
    private var textAlignment: TextAlignment { style == .videoOverlay ? .leading : .center }

    var body: some View {
        // The translation lane comes only from the shared resolution (`QTAppModel.resolvedLyrics`), so this line
        // shows the same translation as the panel and the Stage rail — never the provider's lane in another language.
        let resolved = model?.resolvedLyrics ?? QTResolvedLyrics(document: document, translations: nil,
                                                                 translationLanguage: nil, translationStatus: .off)
        let matches = resolved.document == document
        // Redraws only when the picture changes — the next word lights up or the next line starts — not at a
        // fixed rate (a whole-window SwiftUI update each time).
        let doc = matches ? resolved.document : nil
        QTTickingView(isRunning: time.rate != 0, restartOn: QTStageCurrentLyricClock(time: time, offset: doc?.offset, lines: doc?.lines.count),
                      nextChange: { Self.secondsToNextChange(in: doc, time: time) }) {
            let now = time.currentTime
            let current = matches ? resolved.currentLine(atPlaybackTime: now) : nil
            let index = current?.index
            // Art only, before the first line (intro) or an instrumental track: "Instrumental", like the prototype.
            let isInstrumental = style == .artOnly && matches && resolved.isInstrumental(atPlaybackTime: now)
            ZStack(alignment: style == .videoOverlay ? .bottomLeading : .top) {
            VStack(alignment: alignment, spacing: style == .videoOverlay ? 6 : 4) {
                if isInstrumental {
                    Text(QTLoc.tr("Instrumental"))
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(QTTheme.Colors.onArtSecondary)
                        .accessibilityIdentifier("qt.stage.currentLyric.instrumental")
                } else if let line = current?.line {
                    Text(attributed(line, lyricTime: document?.lyricTime(forPlaybackTime: now) ?? now))
                        .font(style == .videoOverlay ? .system(size: 40, weight: .bold) : .system(size: 22, weight: .semibold))
                        .lineSpacing(2)
                    if showsTranslation, let tr = current?.translation {
                        Text(tr)
                            .font(.system(size: style == .videoOverlay ? 22 : 15, weight: style == .videoOverlay ? .semibold : .regular))
                            .foregroundStyle(.white.opacity(style == .videoOverlay ? 0.86 : 0.6))
                    }
                }
            }
            .multilineTextAlignment(textAlignment)
            .frame(maxWidth: style == .videoOverlay ? 1000 : 560, alignment: Alignment(horizontal: alignment, vertical: .center))
            .id(isInstrumental ? -2 : index ?? -1)
            .transition(QTStageLyricLineTransition.make(reduceMotion: reduceMotion))
            }
            .animation(QTTheme.Motion.animation(QTTheme.Motion.lyricSpring, reduceMotion: reduceMotion), value: index)
        }
        // Subtitle-style over video: a tight dark edge keeps every glyph readable on a bright frame, a wide soft
        // shadow lifts the line off busy pictures (with the scrim QTStageView lays under the lower picture).
        .shadow(color: style == .videoOverlay ? .black.opacity(0.55) : .clear, radius: 1.5, y: 1)
        .shadow(color: style == .videoOverlay ? .black.opacity(0.4) : .clear, radius: 12, y: 2)
        .qtHostsLyricsTranslation(showsTranslation)
        .foregroundStyle(QTTheme.Colors.onArt)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("qt.stage.currentLyric")
    }

    /// Playback seconds until the next word starts or the next line begins (nil: nothing left to change).
    static func secondsToNextChange(in document: QTLyricsDocument?, time: QTPlaybackTimeline) -> TimeInterval? {
        guard let document, time.rate > 0 else { return nil }
        let now = document.lyricTime(forPlaybackTime: time.currentTime)
        let index = document.lineIndex(atPlaybackTime: time.currentTime)
        var next: TimeInterval?
        let following = (index ?? -1) + 1
        if document.lines.indices.contains(following) { next = document.lines[following].start }
        if let index, let words = document.lines[index].words,
           let word = words.first(where: { $0.start > now }) {
            next = min(next ?? .infinity, word.start)
        }
        return next.map { max(0, $0 - now) / time.rate }
    }

    /// Sung words full white, the rest dimmed (`--ly-on` / `--ly-off`). Over video the unsung words stay near-white
    /// (a grey fill would depend on the frame being dark); the sweep reads as brightness, helped by the shadow.
    private func attributed(_ line: QTLyricsLine, lyricTime: TimeInterval) -> AttributedString {
        let off = Color.white.opacity(style == .videoOverlay ? 0.7 : 0.4)
        guard let words = line.words, !words.isEmpty else {
            var s = AttributedString(line.text)
            s.foregroundColor = .white
            return s
        }
        var out = AttributedString()
        for word in words {
            var piece = AttributedString(word.text)
            piece.foregroundColor = word.progress(at: lyricTime) > 0 ? .white : off
            out.append(piece)
        }
        return out
    }
}

/// How one current line hands over to the next. The two lines never share a baseline at full strength: the old
/// one lifts up and out quickly (fading and softening), and the new one rises into place only once the old one has
/// mostly gone — over a moving video two overlapping lines read as garbled text. Reduce Motion: a short fade out,
/// then a fade in, no movement.
enum QTStageLyricLineTransition {
    /// Outgoing line: lift, fade, soften (fast, accelerating away).
    static let exit: TimeInterval = 0.2
    /// The incoming line starts when the outgoing one is ~70 % gone.
    static let entryDelay: TimeInterval = 0.12

    static func make(reduceMotion: Bool) -> AnyTransition {
        if reduceMotion {
            return .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.16).delay(0.12)),
                               removal: .opacity.animation(.easeIn(duration: 0.12)))
        }
        let insertion = AnyTransition.modifier(active: QTStageLyricLineMotion(opacity: 0, y: 18, blur: 6),
                                               identity: QTStageLyricLineMotion(opacity: 1, y: 0, blur: 0))
            .animation(QTTheme.Motion.lyricSpring.delay(entryDelay))
        let removal = AnyTransition.modifier(active: QTStageLyricLineMotion(opacity: 0, y: -30, blur: 8),
                                             identity: QTStageLyricLineMotion(opacity: 1, y: 0, blur: 0))
            .animation(.timingCurve(0.4, 0, 0.9, 0.6, duration: exit))
        return .asymmetric(insertion: insertion, removal: removal)
    }
}

private struct QTStageLyricLineMotion: ViewModifier {
    let opacity: Double
    let y: CGFloat
    let blur: CGFloat

    func body(content: Content) -> some View {
        content
            .blur(radius: blur)
            .offset(y: y)
            .opacity(opacity)
    }
}

/// What re-plans the current line's clock: a seek or play/pause (new timeline), a lyric offset nudge, new lyrics.
private struct QTStageCurrentLyricClock: Hashable {
    var time: QTPlaybackTimeline
    var offset: TimeInterval?
    var lines: Int?
}
