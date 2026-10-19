import AppKit
import Observation
import QTCore
import QTPlayback
import SwiftUI

// Owner: builder "desktop". Menu bar item (draft §4.3): note glyph + "Title — Artist", optionally scrolling;
// its window-style popover holds art, like, scrubber, transport and the current lyric line.

/// Drives the optional marquee. Runs a timer only while scrolling is on, playing and the title overflows.
@MainActor
@Observable
public final class QTMenuBarTicker {
    /// Scroll offset in points.
    public private(set) var offset: CGFloat = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var text: String?
    @ObservationIgnored private var scrolls = false
    @ObservationIgnored private var pauseUntil = Date.distantPast

    static let speed: CGFloat = 18 // pt/s
    static let fps: Double = 30
    static let gap: CGFloat = 48

    func configure(text newText: String?, scrolls newScrolls: Bool) {
        let textChanged = newText != text
        text = newText
        scrolls = newScrolls
        if textChanged { offset = 0; pauseUntil = Date().addingTimeInterval(1.5) }
        let needed = scrolls && (text.map { QTMenuBarLabel.textWidth($0) > QTMenuBarLabel.maxTitleWidth } ?? false)
        if needed, timer == nil {
            pauseUntil = Date().addingTimeInterval(1.5)
            let t = Timer(timeInterval: 1 / Self.fps, repeats: true) { _ in
                MainActor.assumeIsolated { QTDesktopCoordinator.shared.menuBarTicker.step() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !needed, let t = timer {
            t.invalidate()
            timer = nil
            if offset != 0 { offset = 0 }
        }
    }

    private func step() {
        guard let text, Date() >= pauseUntil else { return }
        let cycle = QTMenuBarLabel.textWidth(text) + Self.gap
        var next = offset + Self.speed / CGFloat(Self.fps)
        if next >= cycle {
            next = 0
            pauseUntil = Date().addingTimeInterval(2.5)
        }
        offset = next
    }
}

/// Menu bar item label. Rendered as one template image so long titles get a soft fade instead of an ellipsis
/// and the marquee can scroll; template rendering keeps it correct in light/dark/tinted menu bars.
public struct QTMenuBarLabel: View {
    @Environment(QTPlayerModel.self) private var player
    @Environment(QTAppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    public init() {}

    static let maxTitleWidth: CGFloat = 200
    static var font: NSFont { NSFont.menuBarFont(ofSize: 0) }

    static func titleLine(for track: QTTrack) -> String {
        "\(track.title) — \(track.artistLine)"
    }

    static func textWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    public var body: some View {
        let ticker = QTDesktopCoordinator.shared.menuBarTicker
        let showsTitle = model.settings.settings.showsTitleInMenuBar
        let title = showsTitle ? player.nowPlaying.map(Self.titleLine(for:)) : nil
        Image(nsImage: Self.render(title: title, offset: ticker.offset))
            .accessibilityLabel(player.nowPlaying.map(Self.titleLine(for:)) ?? "QTube Music")
            .onAppear { QTDesktopCoordinator.shared.register(openWindow: openWindow) }
    }

    /// Note glyph + title, black on clear, flagged as a template.
    static func render(title: String?, offset: CGFloat) -> NSImage {
        let height: CGFloat = 22
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let glyph = NSImage(systemSymbolName: QTIcon.note.systemName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        let glyphSize = glyph?.size ?? NSSize(width: 12, height: 14)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let textWidth = title.map { Self.textWidth($0) } ?? 0
        let visibleText = min(textWidth, maxTitleWidth)
        let spacing: CGFloat = title == nil ? 0 : 6
        let width = ceil(glyphSize.width + spacing + visibleText)
        let scale: CGFloat = 2
        guard width > 0, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let gctx = NSGraphicsContext(bitmapImageRep: rep) else { return NSImage() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gctx
        let ctx = gctx.cgContext
        ctx.scaleBy(x: scale, y: scale)
        glyph?.draw(in: NSRect(x: 0, y: ((height - glyphSize.height) / 2).rounded(), width: glyphSize.width, height: glyphSize.height))
        if let title {
            let textRect = NSRect(x: glyphSize.width + spacing, y: 0, width: visibleText, height: height)
            let baseline = ((height - font.ascender + font.descender) / 2 - font.descender).rounded()
            ctx.saveGState()
            ctx.clip(to: textRect)
            let overflow = textWidth > maxTitleWidth
            if overflow {
                // Fade the trailing (and, while scrolling, leading) edge.
                ctx.clip(to: textRect, mask: Self.fadeMask(size: textRect.size, leading: offset > 0))
            }
            let s = title as NSString
            s.draw(at: NSPoint(x: textRect.minX - offset, y: baseline), withAttributes: attrs)
            if overflow && offset > 0 {
                s.draw(at: NSPoint(x: textRect.minX - offset + textWidth + QTMenuBarTicker.gap, y: baseline), withAttributes: attrs)
            }
            ctx.restoreGState()
        }
        NSGraphicsContext.restoreGraphicsState()
        rep.size = NSSize(width: width, height: height) // points; the bitmap is @2x
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }

    private static func fadeMask(size: NSSize, leading: Bool) -> CGImage {
        let w = max(1, Int(size.width * 2)), h = max(1, Int(size.height * 2))
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        let fade = CGFloat(min(28 * 2, w / 3))
        let colors = [CGColor(gray: 1, alpha: 1), CGColor(gray: 0, alpha: 1)] as CFArray
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors, locations: [0, 1])!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.saveGState()
        ctx.clip(to: CGRect(x: CGFloat(w) - fade, y: 0, width: fade, height: CGFloat(h)))
        ctx.drawLinearGradient(g, start: CGPoint(x: CGFloat(w) - fade, y: 0), end: CGPoint(x: CGFloat(w), y: 0), options: [])
        ctx.restoreGState()
        if leading {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: 0, width: fade / 2, height: CGFloat(h)))
            ctx.drawLinearGradient(g, start: CGPoint(x: fade / 2, y: 0), end: CGPoint(x: 0, y: 0), options: [])
            ctx.restoreGState()
        }
        return ctx.makeImage()!
    }
}

/// Menu bar popover: art · title/artist · like, scrubber, transport flanked by desktop lyrics and mini player,
/// then the current lyric line. Follows the system appearance (the popover window draws the material).
public struct QTMenuBarContent: View {
    @Environment(QTAppModel.self) private var model
    @Environment(QTPlayerModel.self) private var player

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            header
            QTScrubber()
                .padding(.top, QTTheme.Spacing.m)
            controls
                .padding(.top, 6)
            if player.ad == nil, player.lyrics != nil {
                Divider()
                    .padding(.top, 14)
                QTCurrentLyricLine(style: .popover)
                    .padding(.top, 12)
            }
        }
        .padding(QTTheme.Spacing.m)
        .frame(width: 300)
        .qtArtworkTint(model.palette)
        .accessibilityIdentifier("qt.menuBarPopover")
    }

    private var header: some View {
        HStack(spacing: QTTheme.Spacing.s) {
            Button {
                QTDesktopCoordinator.shared.showMainWindow()
            } label: {
                QTArtworkView(track: player.nowPlaying, cornerRadius: 7)
                    .frame(width: 56, height: 56)
                    .saturation(player.ad != nil ? 0.6 : 1)
                    .brightness(player.ad != nil ? -0.15 : 0)
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
            }
            .buttonStyle(.plain)
            .help(QTLoc.tr("Show Main Window"))
            .accessibilityLabel(QTLoc.tr("Show Main Window"))

            VStack(alignment: .leading, spacing: 2) {
                if player.ad != nil {
                    Text(QTLoc.tr("Advertisement")).font(QTTheme.Typography.body.weight(.semibold))
                    Text(QTLoc.tr("Then: %@", player.nowPlaying?.title ?? "")).font(QTTheme.Typography.secondary)
                        .foregroundStyle(.secondary)
                } else if let track = player.nowPlaying {
                    Text(track.title).font(QTTheme.Typography.body.weight(.semibold))
                    Text(track.artistLine).font(QTTheme.Typography.secondary).foregroundStyle(.secondary)
                } else {
                    Text(QTLoc.tr("Not Playing", table: .desktop)).font(QTTheme.Typography.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)

            if let track = player.nowPlaying {
                let liked = player.isLiked(track)
                Button {
                    player.toggleLike(track)
                } label: {
                    Label(QTLoc.tr(liked ? "Remove from Liked Songs" : "Like"),
                          systemImage: liked ? QTIcon.heartFill.systemName : QTIcon.heart.systemName)
                        .labelStyle(.iconOnly)
                        .font(.system(size: 15))
                        .foregroundStyle(liked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.borderless)
                .help("\(QTLoc.tr(liked ? "Remove from Liked Songs" : "Like"))  ⌘L")
                .accessibilityIdentifier("qt.menuBarPopover.like")
            }
        }
    }

    private var controls: some View {
        HStack {
            Toggle(isOn: Binding(get: { model.isDesktopLyricsShown }, set: { model.isDesktopLyricsShown = $0 })) {
                Label(QTLoc.tr("Desktop Lyrics"), systemImage: QTIcon.lyrics.systemName)
            }
            .toggleStyle(.button)
            .help("\(QTLoc.tr("Desktop Lyrics"))  ⇧⌘L")
            .accessibilityIdentifier("qt.menuBarPopover.desktopLyrics")
            Spacer()
            QTTransportControls(style: .compact)
            Spacer()
            Button {
                QTDesktopCoordinator.shared.toggleMiniPlayer()
            } label: {
                Label(QTLoc.tr("Mini Player"), systemImage: QTIcon.mini.systemName)
            }
            .help("\(QTLoc.tr("Mini Player"))  ⇧⌘M")
            .accessibilityIdentifier("qt.menuBarPopover.miniPlayer")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
    }
}

/// The current lyric line (plain text, cross-fading between lines) for the menu bar popover and mini player.
/// Uses semantic colours so it works in light, dark and over art.
struct QTCurrentLyricLine: View {
    enum Style { case popover, miniCompact, miniArt }

    @Environment(QTAppModel.self) private var model
    @Environment(QTPlayerModel.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let style: Style

    var body: some View {
        // Lyric + translation from the shared resolution (`QTAppModel.resolvedLyrics`): same lane as every surface.
        let resolved = player.ad == nil ? model.resolvedLyrics : .none
        TimelineView(.periodic(from: .now, by: player.timeline.rate > 0 ? 0.2 : 3600)) { _ in
            let current = resolved.currentLine(atPlaybackTime: player.timeline.currentTime)
            let index = current?.index
            content(current?.line, translation: current?.translation)
                .id(index ?? -1)
                .transition(.opacity)
                .animation(QTTheme.Motion.animation(QTTheme.Motion.lyricScroll, reduceMotion: reduceMotion), value: index)
        }
        .frame(maxWidth: .infinity)
        .qtHostsLyricsTranslation(style == .popover)
        .accessibilityIdentifier("qt.desktop.lyricLine")
    }

    @ViewBuilder
    private func content(_ line: QTLyricsLine?, translation: String?) -> some View {
        switch style {
        case .popover:
            VStack(spacing: 3) {
                Text(line?.text ?? " ")
                    .font(QTTheme.Typography.body.weight(.semibold))
                if let translation, !translation.isEmpty {
                    Text(translation).font(QTTheme.Typography.secondary).foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
            .lineLimit(2)
        case .miniCompact:
            Text(line?.text ?? " ")
                .font(QTTheme.Typography.secondary.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .miniArt:
            Text(line?.text ?? " ")
                .font(QTTheme.Typography.body.weight(.semibold))
                .foregroundStyle(QTTheme.Colors.onArt)
                .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
    }
}
