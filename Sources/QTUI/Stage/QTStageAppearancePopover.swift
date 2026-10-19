import AppKit
import QTCore
import SwiftUI

/// The quiet Appearance icon in the Stage top bar → one system popover with the layout pictograms (a native
/// segmented control with tooltips) and the background swatches (live miniatures, like System Settings ›
/// Wallpaper).
struct QTStageAppearanceButton: View {
    @Binding var isPresented: Bool
    let appearance: QTStageResolvedAppearance

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label(QTLoc.tr("Appearance"), systemImage: QTIcon.sparkle.systemName)
        }
        .buttonStyle(QTStageChromeButtonStyle(isOn: isPresented))
        .help(QTLoc.tr("Appearance"))
        .accessibilityIdentifier("qt.stage.appearanceButton")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            QTStageAppearancePopover(appearance: appearance)
                // The Stage is always dark; keep its popover dark even under a light app theme.
                .preferredColorScheme(.dark)
        }
    }
}

struct QTStageAppearancePopover: View {
    let appearance: QTStageResolvedAppearance
    @Environment(QTAppModel.self) private var model
    @Environment(QTPlayerModel.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isPremium: Bool { model.account == .premium }
    private var hasVideo: Bool { player.nowPlaying?.hasVideo ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !appearance.isVideo {
                QTStageLayoutPicker(selection: layoutBinding)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(QTLoc.tr("Stage layout"))
                    .accessibilityIdentifier("qt.stage.appearance.layout")
                Divider()
            }
            HStack(alignment: .top, spacing: 6) {
                ForEach(QTStageBackground.allCases, id: \.self) { bg in
                    swatch(bg)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(QTLoc.tr("Stage background"))
        }
        .padding(14)
        .frame(width: 360)
        .accessibilityIdentifier("qt.stage.appearancePopover")
    }

    private var layoutBinding: Binding<QTStageLayout> {
        Binding(get: { model.stageLayout }, set: { new in
            withAnimation(QTTheme.Motion.animation(QTTheme.Motion.spring, reduceMotion: reduceMotion)) { model.stageLayout = new }
        })
    }

    private func isEnabled(_ bg: QTStageBackground) -> Bool {
        switch bg {
        case .video: hasVideo
        case .visualizer: isPremium
        default: true
        }
    }

    private func title(_ bg: QTStageBackground) -> String {
        switch bg {
        case .blur: QTLoc.tr("Blur")
        case .cover: QTLoc.tr("Cover")
        case .vinyl: QTLoc.tr("Vinyl")
        case .video: QTLoc.tr("Video")
        case .visualizer: QTLoc.tr("Visualizer")
        }
    }

    private func help(_ bg: QTStageBackground) -> String {
        switch bg {
        case .blur: QTLoc.tr("Blurred artwork")
        case .cover: QTLoc.tr("Full-bleed cover")
        case .vinyl: QTLoc.tr("Vinyl")
        case .video: hasVideo ? QTLoc.tr("Music video") : QTLoc.tr("No official music video for this song")
        case .visualizer: isPremium ? QTLoc.tr("Visualizer") : QTLoc.tr("Visualizer needs the Premium engine", table: .stage)
        }
    }

    private func swatch(_ bg: QTStageBackground) -> some View {
        let selected = appearance.selectedSwatch == bg
        let enabled = isEnabled(bg)
        return Button {
            select(bg)
        } label: {
            VStack(spacing: 6) {
                QTStageSwatchPreview(background: bg, track: player.nowPlaying, enabled: enabled)
                    .frame(width: 56, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        // Hairline so dark previews don't melt into the popover.
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
                    }
                    .padding(3)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2.5)
                    }
                Text(title(bg))
                    .font(QTTheme.Typography.caption.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : enabled ? .secondary : .tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help(bg))
        .accessibilityLabel(title(bg))
        .accessibilityHint(enabled ? "" : help(bg))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("qt.stage.appearance.background.\(bg.rawValue)")
    }

    private func select(_ bg: QTStageBackground) {
        withAnimation(QTTheme.Motion.animation(QTTheme.Motion.ui, reduceMotion: reduceMotion)) {
            model.stageBackground = bg
            model.isVideoMode = bg == .video
        }
    }
}

// MARK: - Layout picker

/// Native segmented control with drawn layout pictograms (art + lyrics · lyrics · art) and a tooltip per segment.
/// AppKit because SwiftUI's segmented Picker can't give each segment its own tooltip or a custom template image.
struct QTStageLayoutPicker: NSViewRepresentable {
    @Binding var selection: QTStageLayout

    static let layouts: [QTStageLayout] = [.standard, .lyricsOnly, .artOnly]

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentCount = Self.layouts.count
        control.trackingMode = .selectOne
        control.segmentDistribution = .fillEqually
        control.controlSize = .large
        control.target = context.coordinator
        control.action = #selector(QTStageLayoutPickerCoordinator.changed(_:))
        control.setAccessibilityIdentifier("qt.stage.appearance.layoutControl")
        for (i, layout) in Self.layouts.enumerated() {
            control.setImage(QTStageLayoutGlyph.image(for: layout), forSegment: i)
            control.setImageScaling(.scaleNone, forSegment: i)
        }
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        for (i, layout) in Self.layouts.enumerated() {
            let name = Self.title(layout)
            control.setToolTip(name, forSegment: i)
            control.image(forSegment: i)?.accessibilityDescription = name
        }
        if let index = Self.layouts.firstIndex(of: selection), control.selectedSegment != index {
            control.selectedSegment = index
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        let natural = nsView.intrinsicContentSize
        return CGSize(width: proposal.width ?? natural.width, height: natural.height)
    }

    func makeCoordinator() -> QTStageLayoutPickerCoordinator { QTStageLayoutPickerCoordinator(selection: $selection) }

    static func title(_ layout: QTStageLayout) -> String {
        switch layout {
        case .standard: QTLoc.tr("Art + lyrics")
        case .lyricsOnly: QTLoc.tr("Lyrics")
        case .artOnly: QTLoc.tr("Art")
        }
    }
}

@MainActor
final class QTStageLayoutPickerCoordinator: NSObject {
    var selection: Binding<QTStageLayout>

    init(selection: Binding<QTStageLayout>) {
        self.selection = selection
    }

    @objc func changed(_ sender: NSSegmentedControl) {
        let layouts = QTStageLayoutPicker.layouts
        guard layouts.indices.contains(sender.selectedSegment) else { return }
        selection.wrappedValue = layouts[sender.selectedSegment]
    }
}

/// Template pictograms of the three Stage layouts (the prototype's layout tiles), 30 × 18 pt.
enum QTStageLayoutGlyph {
    static func image(for layout: QTStageLayout) -> NSImage {
        let image = NSImage(size: NSSize(width: 30, height: 18), flipped: true) { _ in
            NSColor.black.setFill()
            func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat) {
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: 2), xRadius: 1, yRadius: 1).fill()
            }
            func tile(_ rect: NSRect) {
                NSBezierPath(roundedRect: rect, xRadius: 2.5, yRadius: 2.5).fill()
            }
            switch layout {
            case .standard:
                tile(NSRect(x: 2, y: 3, width: 12, height: 12))
                bar(17, 4, 11)
                bar(17, 8, 8)
                bar(17, 12, 10)
            case .lyricsOnly:
                bar(7, 2.5, 16)
                bar(9, 6.5, 12)
                bar(6, 10.5, 18)
                bar(10, 14.5, 10)
            case .artOnly:
                tile(NSRect(x: 9, y: 1.5, width: 12, height: 12))
                bar(11, 15, 8)
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

// MARK: - Swatch previews

/// Live miniatures of each background, drawn from the current track with the same processed images the Stage
/// uses (so Blur looks like the Stage's blur, Cover like its frosted cover, and so on).
struct QTStageSwatchPreview: View {
    let background: QTStageBackground
    let track: QTTrack?
    let enabled: Bool

    private var art: [QTArtworkImage] { track?.artwork ?? [] }

    var body: some View {
        ZStack {
            QTTheme.Colors.stageBase(track?.palette)
            switch background {
            case .blur:
                processed(art, .blurredArt)
            case .cover:
                processed(art, .coverSoft)
                LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
            case .vinyl:
                processed(art, .blurredArt)
                QTStageSwatchRecord(track: track)
                    .frame(width: 32, height: 32)
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 2)
            case .video:
                if enabled {
                    processed(track?.videoArtwork ?? [], .videoStill)
                    LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .center, endPoint: .bottom)
                } else {
                    processed(art, .blurredArt)
                        .saturation(0)
                        .opacity(0.5)
                }
            case .visualizer:
                processed(art, .blurredArt)
                QTStageSwatchBars(palette: track?.palette)
            }
        }
        .saturation(enabled ? 1 : 0.15)
        .opacity(enabled ? 1 : 0.55)
        .accessibilityHidden(true)
    }

    private func processed(_ images: [QTArtworkImage], _ look: QTStageImageProcessor.Look) -> some View {
        QTStageProcessedImage(images: images, look: look) { image in
            // Always a real view (not an empty optional), so the loader's `.task` runs.
            ZStack {
                Color.clear
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .transition(.opacity)
                }
            }
            .frame(width: 56, height: 40)
            .clipped()
        }
    }
}

/// A tiny record: grooves and the cover as its label.
private struct QTStageSwatchRecord: View {
    let track: QTTrack?

    var body: some View {
        ZStack {
            Canvas { ctx, size in
                let r = min(size.width, size.height) / 2
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(Color(white: 0.06)))
                var radius = r - 1.5
                while radius > r * 0.42 {
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)),
                               with: .color(Color(white: 0.16)), lineWidth: 0.4)
                    radius -= 1.6
                }
            }
            QTArtworkView(track: track, cornerRadius: 0)
                .frame(width: 12, height: 12)
                .clipShape(Circle())
            Circle()
                .fill(AngularGradient(colors: [.clear, .white.opacity(0.12), .clear, .clear, .white.opacity(0.08), .clear],
                                      center: .center))
        }
    }
}

/// The visualizer's resting spectrum in miniature, in the artwork's colours.
private struct QTStageSwatchBars: View {
    let palette: QTArtworkPalette?

    var body: some View {
        let colors = QTStageVisualizerView.colors(palette: palette, accent: QTTheme.Colors.systemAccent)
        let base = Color(.sRGB, red: Double(colors.base.x), green: Double(colors.base.y), blue: Double(colors.base.z))
        let tip = Color(.sRGB, red: Double(colors.tip.x), green: Double(colors.tip.y), blue: Double(colors.tip.z))
        Canvas { ctx, size in
            let count = 14
            let slot = size.width / CGFloat(count)
            let shape = QTStageVisualizerRenderer.synthetic(t: 2.2, playing: true)
            for i in 0..<count {
                let sample = shape[i * shape.count / count]
                let h = max(CGFloat(sample) / CGFloat(QTStageVisualizerRenderer.peak) * size.height * 0.62, 3)
                let rect = CGRect(x: CGFloat(i) * slot + slot * 0.22, y: size.height - h, width: slot * 0.56, height: h + 2)
                ctx.fill(Path(roundedRect: rect, cornerRadius: slot * 0.28),
                         with: .linearGradient(Gradient(colors: [tip, base]), startPoint: CGPoint(x: 0, y: size.height - h),
                                               endPoint: CGPoint(x: 0, y: size.height)))
            }
        }
        .opacity(0.9)
    }
}
