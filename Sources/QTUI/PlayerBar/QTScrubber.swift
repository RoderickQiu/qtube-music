import QTCore
import QTPlayback
import SwiftUI

// Owner: builder "player". Shared by the player bar, Stage, mini player and menu bar popover.

/// Elapsed · progress · remaining, tinted with the artwork accent.
///
/// Drawn like the progress bar in Music.app's player (a thin capsule that thickens and shows its knob on hover)
/// rather than an `NSSlider`, because a slider's fill turns grey whenever the window isn't key and the spec asks
/// for an artwork-tinted progress bar. It behaves like a native adjustable control: VoiceOver adjustable action,
/// keyboard focus (Full Keyboard Access) with ←/→ = ∓5 s, click or drag to seek. While an ad plays it shows
/// "Ad" · the ad countdown in system yellow and is disabled.
public struct QTScrubber: View {
    private let overArt: Bool
    @Environment(QTPlayerModel.self) private var player

    public init(overArt: Bool = false) {
        self.overArt = overArt
    }

    public var body: some View {
        let ad = player.ad
        // Re-render 4×/s while time moves (playing or ad countdown); otherwise only on state changes.
        TimelineView(.periodic(from: .now, by: player.timeline.rate > 0 || (ad != nil && player.isPlaying) ? 0.25 : 3600)) { _ in
            QTScrubberContent(overArt: overArt, ad: ad, time: player.timeline.currentTime,
                              duration: player.duration) { player.seek(to: $0) }
        }
    }
}

private struct QTScrubberContent: View {
    let overArt: Bool
    let ad: QTAdState?
    let time: TimeInterval
    let duration: TimeInterval
    let onSeek: (TimeInterval) -> Void

    @Environment(\.qtAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var dragFraction: Double?
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    private var safeDuration: TimeInterval { max(duration, 1) }
    private var shownTime: TimeInterval { dragFraction.map { $0 * safeDuration } ?? time }
    private var fraction: Double {
        if let ad { return ad.progress }
        return min(1, max(0, shownTime / safeDuration))
    }

    private var leading: String { ad != nil ? QTLoc.tr("Ad") : QTFormat.duration(shownTime) }
    private var trailing: String {
        if let ad { return QTFormat.duration(ad.remaining.rounded(.up)) }
        return QTFormat.remaining(safeDuration - shownTime)
    }

    private var labelColor: Color { overArt ? QTTheme.Colors.onArtSecondary : QTTheme.Colors.secondaryLabel }
    private var trackColor: Color {
        if overArt { return .white.opacity(contrast == .increased ? 0.4 : 0.22) }
        return contrast == .increased ? QTTheme.Colors.tertiaryLabel : QTTheme.Colors.quaternaryLabel
    }
    private var fillColor: Color {
        if ad != nil { return Color(nsColor: .systemYellow) }
        return overArt ? .white.opacity(0.92) : accent
    }

    private var isActive: Bool { (isHovering || dragFraction != nil || isFocused) && ad == nil }

    var body: some View {
        HStack(spacing: QTTheme.Spacing.xs) {
            Text(leading)
                .frame(width: 44, alignment: .trailing)
            bar
            Text(trailing)
                .frame(width: 44, alignment: .leading)
        }
        .font(QTTheme.Typography.caption)
        .monospacedDigit()
        .foregroundStyle(labelColor)
        .lineLimit(1)
    }

    private var bar: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let thickness: CGFloat = isActive ? 6 : 4
            ZStack(alignment: .leading) {
                Capsule().fill(trackColor)
                    .frame(height: thickness)
                Capsule().fill(fillColor)
                    .frame(width: max(thickness, width * fraction), height: thickness)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                    .frame(width: 12, height: 12)
                    .offset(x: width * fraction - 6)
                    .opacity(isActive ? 1 : 0)
                    .scaleEffect(isActive ? 1 : 0.5)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard ad == nil else { return }
                        dragFraction = min(1, max(0, value.location.x / width))
                    }
                    .onEnded { value in
                        guard ad == nil else { return }
                        let f = min(1, max(0, value.location.x / width))
                        onSeek(f * safeDuration)
                        dragFraction = nil
                    }
            )
        }
        .frame(height: 16)
        .animation(QTTheme.Motion.animation(.spring(response: 0.24, dampingFraction: 0.9), reduceMotion: reduceMotion), value: isActive)
        .opacity(ad != nil ? 0.85 : 1)
        .onHover { isHovering = $0 }
        .focusable(ad == nil, interactions: .activate)
        .focused($isFocused)
        .onKeyPress(.leftArrow) { onSeek(max(0, time - 5)); return .handled }
        .onKeyPress(.rightArrow) { onSeek(min(safeDuration, time + 5)); return .handled }
        .accessibilityElement()
        .accessibilityLabel(QTLoc.tr("Time"))
        .accessibilityValue(ad != nil ? "\(QTLoc.tr("Ad")) \(trailing)" : "\(QTFormat.duration(shownTime)) / \(QTFormat.duration(safeDuration))")
        .accessibilityAdjustableAction { direction in
            guard ad == nil else { return }
            switch direction {
            case .increment: onSeek(min(safeDuration, time + 10))
            case .decrement: onSeek(max(0, time - 10))
            @unknown default: break
            }
        }
        .accessibilityIdentifier("qt.player.scrubber")
    }
}
