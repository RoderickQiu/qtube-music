import QTCore
import QTPlayback
import SwiftUI

// Owner: builder "lyrics-ui". Development harness (`-qt.lyrics.lab YES`): every lyric style side by side with the
// scripts that break naive font stacks — Vietnamese stacked diacritics ("Đối Với Anh Em", "Hạ Phỏm", "Trú Mưa"),
// Simplified/Traditional Chinese, Japanese, Korean — with the karaoke fill frozen mid-line. Not user-facing; no
// localized copy (labels are verbatim style names).

/// Overlay host: renders nothing unless the launch option is set.
public struct QTLyricsLabOverlay: View {
    @Environment(QTAppModel.self) private var model

    public init() {}

    public var body: some View {
        if model.launch.bool("qt.lyrics.lab") == true {
            QTLyricsLab()
                .transition(.opacity)
        }
    }
}

struct QTLyricsLab: View {
    private static let words: [(String, String?)] = [
        ("Đối Với Anh Em Không Còn Cảm Giác", "对你来说我已没有感觉"),
        ("Hạ Phỏm — Ngồi Hát Đỡ Buồn", "出牌 · 坐着唱歌解闷"),
        ("Trú Mưa · Đơn Côi · Chúng Ta Của Hiện Tại", "避雨 · 孤单 · 现在的我们"),
        ("故事的小黄花 從出生那年就飄著", "The little yellow flower of the story"),
        ("夜に駆ける · 우리의 밤", "Racing into the night · Our night"),
    ]

    /// Lines with even word timing; lyric time 2.4 s sits inside the first line.
    private static let document: QTLyricsDocument = {
        var lines: [QTLyricsLine] = []
        var t: TimeInterval = 0
        for (text, tr) in words {
            let parts = text.split(separator: " ", omittingEmptySubsequences: false)
            var ws: [QTLyricsWord] = []
            var wt = t
            for (i, p) in parts.enumerated() {
                let s = i < parts.count - 1 ? String(p) + " " : String(p)
                ws.append(QTLyricsWord(start: wt, duration: 0.6, text: s))
                wt += 0.6
            }
            lines.append(QTLyricsLine(start: t, duration: wt - t, text: text, words: ws, translation: tr))
            t = wt + 0.4
        }
        return QTLyricsDocument(lines: lines, syncKind: .word, source: .netease, language: "vi",
                                translationLanguage: "zh-Hans")
    }()

    private var timeline: QTPlaybackTimeline { QTPlaybackTimeline(time: 2.5, rate: 0, duration: 60) }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                label("panel")
                QTLyricsView(document: Self.document, time: timeline, style: .panel, onSeek: { _ in })
            }
            .frame(width: 420)
            .background(.regularMaterial)
            VStack(alignment: .leading, spacing: 8) {
                label("stage")
                QTLyricsView(document: Self.document, time: timeline, style: .stage(centered: false), onSeek: { _ in })
                    .environment(\.colorScheme, .dark)
                label("desktop · mini")
                QTLyricsView(document: Self.document, time: timeline, style: .desktop, onSeek: { _ in })
                    .frame(height: 110)
                QTLyricsView(document: Self.document, time: timeline, style: .mini, onSeek: { _ in })
                    .frame(height: 40)
                    .padding(.horizontal, 12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .frame(width: 340)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(LinearGradient(colors: [Color(red: 0.32, green: 0.1, blue: 0.14), Color(red: 0.1, green: 0.06, blue: 0.16)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .accessibilityIdentifier("qt.lyrics.lab")
    }

    private func label(_ s: String) -> some View {
        Text(verbatim: s)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .padding(.leading, 12)
            .padding(.top, 8)
    }
}
