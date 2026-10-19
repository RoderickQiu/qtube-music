import QTCore
import SwiftUI

/// The quiet Appearance icon in the Stage top bar → one system popover with the layout glyphs (segmented) and
/// the background swatches (thumbnail picker, like System Settings › Appearance).
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
        VStack(alignment: .leading, spacing: QTTheme.Spacing.s) {
            if !appearance.isVideo {
                Picker(selection: layoutBinding) {
                    Label(QTLoc.tr("Art + lyrics"), systemImage: "rectangle.split.2x1").tag(QTStageLayout.standard)
                    Label(QTLoc.tr("Lyrics"), systemImage: "text.aligncenter").tag(QTStageLayout.lyricsOnly)
                    Label(QTLoc.tr("Art"), systemImage: "photo").tag(QTStageLayout.artOnly)
                } label: {
                    Text(QTLoc.tr("Stage layout"))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .labelStyle(.iconOnly)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
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
            if !isPremium {
                Text(QTLoc.tr("Visualizer needs the Premium engine", table: .stage))
                    .font(QTTheme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityIdentifier("qt.stage.appearance.visualizerReason")
            }
        }
        .padding(QTTheme.Spacing.s)
        .frame(width: 320)
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
            VStack(spacing: 5) {
                QTStageSwatchPreview(background: bg, track: player.nowPlaying, enabled: enabled)
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(2.5)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10.5, style: .continuous)
                            .strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2.5)
                    }
                Text(title(bg))
                    .font(QTTheme.Typography.caption.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .help(help(bg))
        .accessibilityLabel(title(bg))
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

/// Small live previews of each background, drawn from the current track.
struct QTStageSwatchPreview: View {
    let background: QTStageBackground
    let track: QTTrack?
    let enabled: Bool
    @Environment(\.qtAccent) private var accent

    var body: some View {
        ZStack {
            QTTheme.Colors.fill
            switch background {
            case .blur:
                QTArtworkView(track: track, cornerRadius: 0)
                    .scaleEffect(1.3)
                    .blur(radius: 6)
                    .saturation(1.4)
            case .cover:
                QTArtworkView(track: track, cornerRadius: 0)
            case .vinyl:
                ZStack {
                    Color.black
                    Circle()
                        .fill(RadialGradient(colors: [Color(white: 0.1), Color(white: 0.05)], center: .center,
                                             startRadius: 0, endRadius: 25))
                    QTArtworkView(track: track, cornerRadius: 0)
                        .frame(width: 18, height: 18)
                        .clipShape(Circle())
                }
                .clipShape(Circle())
            case .video:
                if enabled {
                    QTArtworkView(track: track, video: true, cornerRadius: 0)
                }
            case .visualizer:
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(Array([5, 9, 6, 11, 7, 4, 8].enumerated()), id: \.offset) { _, h in
                        RoundedRectangle(cornerRadius: 1).fill(accent).frame(width: 4, height: CGFloat(h) * 3)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 8)
            }
        }
    }
}
