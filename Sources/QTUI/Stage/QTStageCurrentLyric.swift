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

    private var surface: QTTheme.Typography.LyricSurface { style == .videoOverlay ? .videoOverlay : .artOnly }
    private var alignment: HorizontalAlignment { style == .videoOverlay ? .leading : .center }
    private var textAlignment: TextAlignment { style == .videoOverlay ? .leading : .center }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: time.rate == 0)) { _ in
            let now = time.currentTime
            let index = document?.lineIndex(atPlaybackTime: now)
            let line = index.flatMap { document?.lines[$0] }
            ZStack {
            VStack(alignment: alignment, spacing: style == .videoOverlay ? 6 : 4) {
                if let line {
                    Text(attributed(line, lyricTime: document?.lyricTime(forPlaybackTime: now) ?? now))
                        .font(style == .videoOverlay ? .system(size: 40, weight: .bold) : .system(size: 22, weight: .semibold))
                        .lineSpacing(2)
                    if showsTranslation, let tr = line.translation, !tr.isEmpty {
                        Text(tr)
                            .font(.system(size: style == .videoOverlay ? 22 : 15, weight: style == .videoOverlay ? .semibold : .regular))
                            .foregroundStyle(.white.opacity(style == .videoOverlay ? 0.75 : 0.6))
                    }
                }
            }
            .multilineTextAlignment(textAlignment)
            .frame(maxWidth: style == .videoOverlay ? 1000 : 560, alignment: Alignment(horizontal: alignment, vertical: .center))
            .id(index ?? -1)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: reduceMotion ? 0 : 10)),
                                    removal: .opacity.combined(with: .offset(y: reduceMotion ? 0 : -10))))
            }
            .animation(QTTheme.Motion.animation(QTTheme.Motion.lyricSpring, reduceMotion: reduceMotion), value: index)
        }
        .shadow(color: style == .videoOverlay ? .black.opacity(0.5) : .clear, radius: 9, y: 2)
        .foregroundStyle(QTTheme.Colors.onArt)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("qt.stage.currentLyric")
    }

    /// Sung words full white, the rest dimmed (`--ly-on` / `--ly-off`).
    private func attributed(_ line: QTLyricsLine, lyricTime: TimeInterval) -> AttributedString {
        let off = Color.white.opacity(style == .videoOverlay ? 0.45 : 0.4)
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
