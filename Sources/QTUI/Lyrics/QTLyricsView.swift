import QTCore
import QTPlayback
import SwiftUI

// Owner: builder "lyrics-ui". The public signature below is the shared contract (used by NowPlaying, Stage,
// Desktop); replace the body freely (word-level karaoke in Core Animation, spring scroll, free scrolling with a
// "Current" jump-back, per-script fonts, selectable text). Add parameters only with defaults.

/// Where a lyrics view is shown; each has its own type size, alignment and colour context.
public enum QTLyricsStyle: Hashable, Sendable {
    /// Docked panel: left-aligned, 19/14 pt, system label colours.
    case panel
    /// Stage: 34/22 pt over art (white), leading or centred (Lyrics-only layout).
    case stage(centered: Bool)
    /// Mini player / menu bar: the current line only.
    case mini
    /// Desktop lyrics overlay: one or two big lines with shadow, click-through.
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
        case .panel: false
        default: true
        }
    }

    var isCentered: Bool {
        switch self {
        case .stage(let c): c
        case .desktop: true
        default: false
        }
    }
}

/// Synced lyrics. `time` is the playback timeline (anchor + rate) so this view interpolates the position
/// itself at display rate; the parent only re-renders on play/pause/seek. `onSeek` receives a playback time.
public struct QTLyricsView: View {
    private let document: QTLyricsDocument?
    private let time: QTPlaybackTimeline
    private let style: QTLyricsStyle
    private let showsTranslation: Bool
    private let onSeek: (TimeInterval) -> Void

    public init(document: QTLyricsDocument?, time: QTPlaybackTimeline, style: QTLyricsStyle,
                showsTranslation: Bool = true, onSeek: @escaping (TimeInterval) -> Void) {
        self.document = document
        self.time = time
        self.style = style
        self.showsTranslation = showsTranslation
        self.onSeek = onSeek
    }

    public var body: some View {
        if let document, !document.lines.isEmpty {
            TimelineView(.periodic(from: .now, by: time.rate > 0 ? 0.1 : 3600)) { _ in
                let current = document.lineIndex(atPlaybackTime: time.currentTime)
                lines(document, current: current)
            }
        } else {
            Text(QTLoc.tr("No lyrics"))
                .font(QTTheme.Typography.body)
                .foregroundStyle(style.isOverArt ? QTTheme.Colors.onArtTertiary : QTTheme.Colors.tertiaryLabel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func lines(_ doc: QTLyricsDocument, current: Int?) -> some View {
        switch style {
        case .mini, .desktop:
            let line = current.map { doc.lines[$0] }
            VStack(spacing: 4) {
                Text(line?.text ?? "")
                    .font(QTTheme.Typography.lyric(style.surface))
                if showsTranslation, let tr = line?.translation {
                    Text(tr).font(QTTheme.Typography.lyricTranslation(style.surface)).opacity(0.75)
                }
            }
            .foregroundStyle(style.isOverArt ? QTTheme.Colors.onArt : QTTheme.Colors.label)
            .multilineTextAlignment(.center)
        case .panel, .stage:
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: style.isCentered ? .center : .leading, spacing: style.surface == .stage ? 24 : 14) {
                        ForEach(Array(doc.lines.enumerated()), id: \.offset) { i, line in
                            lineView(line, isCurrent: i == current)
                                .id(i)
                                .onTapGesture { onSeek(doc.playbackTime(forLine: i)) }
                        }
                    }
                    .padding(.vertical, 120)
                    .padding(.horizontal, style.surface == .panel ? 30 : 0)
                }
                .scrollIndicators(.never)
                .onChange(of: current) { _, new in
                    guard let new else { return }
                    withAnimation(QTTheme.Motion.lyricScroll) { proxy.scrollTo(new, anchor: UnitPoint(x: 0, y: 0.36)) }
                }
                .onAppear { if let current { proxy.scrollTo(current, anchor: UnitPoint(x: 0, y: 0.36)) } }
            }
        }
    }

    private func lineView(_ line: QTLyricsLine, isCurrent: Bool) -> some View {
        let primary: Color = style.isOverArt ? QTTheme.Colors.onArt : QTTheme.Colors.label
        let secondary: Color = style.isOverArt ? QTTheme.Colors.onArtSecondary : QTTheme.Colors.secondaryLabel
        return VStack(alignment: style.isCentered ? .center : .leading, spacing: 3) {
            Text(line.text)
                .font(QTTheme.Typography.lyric(style.surface))
                .foregroundStyle(primary)
            if showsTranslation, let tr = line.translation, !tr.isEmpty {
                Text(tr)
                    .font(QTTheme.Typography.lyricTranslation(style.surface))
                    .foregroundStyle(secondary)
            }
        }
        .multilineTextAlignment(style.isCentered ? .center : .leading)
        .opacity(isCurrent ? 1 : 0.32)
        .contentShape(Rectangle())
    }
}
