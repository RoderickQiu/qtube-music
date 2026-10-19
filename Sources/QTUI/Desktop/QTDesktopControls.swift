import AppKit
import QTCore
import SwiftUI

// Owner: builder "desktop". Small pieces shared by the mini player and the menu bar popover: a compact
// previous / play / next cluster sized for a 72 pt strip, and a single-line title that scrolls (marquee) when it
// doesn't fit and the pointer is over it.

/// Previous · play/pause · next at mini-player scale (prototype: 15 / 18 / 15 px glyphs, 14 px gaps). The player
/// bar's `QTTransportControls(.compact)` is sized for a 300 pt popover row and crowds the mini player's title.
struct QTMiniTransportControls: View {
    enum Size { case small, regular }

    @Environment(QTPlayerModel.self) private var player
    var size: Size = .small

    private var glyph: CGFloat { size == .small ? 13 : 15 }
    private var playGlyph: CGFloat { size == .small ? 17 : 20 }

    var body: some View {
        let ad = player.ad
        HStack(spacing: size == .small ? 1 : 8) {
            button(QTLoc.tr("Previous"), symbol: QTIcon.prev.systemName, glyph: glyph, id: "previous",
                   help: "\(QTLoc.tr("Previous"))  ⌘←") {
                Task { await player.previous() }
            }
            .disabled(ad != nil)

            button(QTLoc.tr(player.isPlaying ? "Pause" : "Play"),
                   symbol: player.isPlaying ? QTIcon.pause.systemName : QTIcon.play.systemName,
                   glyph: playGlyph, id: "playPause", help: "\(QTLoc.tr(player.isPlaying ? "Pause" : "Play"))  Space") {
                player.togglePlayPause()
            }

            button(QTLoc.tr(ad != nil ? "Skip" : "Next"), symbol: QTIcon.next.systemName, glyph: glyph, id: "next",
                   help: ad != nil ? QTLoc.tr("Skip") : "\(QTLoc.tr("Next"))  ⌘→") {
                if let ad {
                    if ad.canSkip { player.skipAd() }
                } else {
                    Task { await player.next() }
                }
            }
            .disabled(ad.map { !$0.canSkip } ?? false)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        // Label colour, like Music's mini player; the artwork accent stays on the progress line.
        .foregroundStyle(.primary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("qt.desktop.transport")
    }

    private func button(_ title: String, symbol: String, glyph: CGFloat, id: String, help: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: glyph, weight: .medium))
                .frame(width: glyph + 10, height: 28)
                .contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace.downUp))
        }
        .help(help)
        .accessibilityIdentifier("qt.desktop.transport.\(id)")
    }
}

/// One line of text that truncates normally and, while `isActive` (hover), scrolls when it doesn't fit — like
/// Music's mini player. Respects Reduce Motion (stays truncated).
struct QTMarqueeText: View {
    let text: String
    let font: Font
    /// AppKit twin of `font`, for measuring.
    let measureFont: NSFont
    var isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    static let speed: Double = 28 // pt/s
    static let pause: Double = 1.4 // s at the start of each pass
    static let gap: CGFloat = 36

    var body: some View {
        let width = ceil((text as NSString).size(withAttributes: [.font: measureFont]).width)
        // The hidden copy gives the line its natural height and lets the parent decide the width.
        Text(text)
            .font(font)
            .lineLimit(1)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                GeometryReader { g in
                    if isActive, !reduceMotion, width > g.size.width + 1 {
                        scrolling(width: width, box: g.size)
                    } else {
                        Text(text)
                            .font(font)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(width: g.size.width, height: g.size.height, alignment: .leading)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .onChange(of: isActive) { _, active in if active { start = .now } }
    }

    private func scrolling(width: CGFloat, box: CGSize) -> some View {
        let cycle = Double(width + Self.gap)
        let period = cycle / Self.speed + Self.pause
        return TimelineView(.animation) { context in
            let t = context.date.timeIntervalSince(start).truncatingRemainder(dividingBy: period)
            let offset = CGFloat(max(0, t - Self.pause) * Self.speed)
            HStack(spacing: Self.gap) {
                Text(text)
                Text(text)
            }
            .font(font)
            .lineLimit(1)
            .fixedSize()
            .offset(x: -offset)
            .frame(width: box.width, height: box.height, alignment: .leading)
            .clipped()
            .mask {
                LinearGradient(stops: [.init(color: offset > 0 ? .clear : .black, location: 0),
                                       .init(color: .black, location: 0.06),
                                       .init(color: .black, location: 0.88),
                                       .init(color: .clear, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
            }
        }
    }
}
