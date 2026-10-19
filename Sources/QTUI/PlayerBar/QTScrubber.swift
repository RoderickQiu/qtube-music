import AppKit
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
/// "Ad" · the ad countdown in the amber ad tint (`QTAdTint`) and is disabled.
public struct QTScrubber: View {
    private let overArt: Bool
    private let identifier: String
    @Environment(QTPlayerModel.self) private var player

    /// - Parameter identifier: accessibility identifier of the slider (`qt.stage.scrubber` on the Stage).
    public init(overArt: Bool = false, identifier: String = "qt.player.scrubber") {
        self.overArt = overArt
        self.identifier = identifier
    }

    public var body: some View {
        let ad = player.ad
        // Re-render 4×/s while time moves (playing or ad countdown); otherwise only on state changes.
        TimelineView(.periodic(from: .now, by: player.timeline.rate > 0 || (ad != nil && player.isPlaying) ? 0.25 : 3600)) { _ in
            QTScrubberContent(overArt: overArt, identifier: identifier, ad: ad, time: player.timeline.currentTime,
                              duration: player.duration) { player.seek(to: $0) }
        }
    }
}

private struct QTScrubberContent: View {
    let overArt: Bool
    let identifier: String
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
        if ad != nil { return QTAdTint.color(overArt: overArt, increasedContrast: contrast == .increased) }
        return overArt ? .white.opacity(0.92) : accent
    }

    private var isActive: Bool { (isHovering || dragFraction != nil || isFocused) && ad == nil }

    var body: some View {
        HStack(spacing: QTTheme.Spacing.xs) {
            Text(leading)
                .fontWeight(ad != nil ? .semibold : nil)
                .foregroundStyle(ad != nil ? QTAdTint.color(overArt: overArt, increasedContrast: contrast == .increased) : labelColor)
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
        .onHover { isHovering = $0 }
        .focusable(ad == nil, interactions: .activate)
        .focused($isFocused)
        .onKeyPress(.leftArrow) { onSeek(max(0, time - 5)); return .handled }
        .onKeyPress(.rightArrow) { onSeek(min(safeDuration, time + 5)); return .handled }
        // To VoiceOver and Voice Control it *is* a slider (AXSlider, "slider"), valued in playback time.
        .accessibilityRepresentation {
            Slider(value: Binding(get: { shownTime }, set: { onSeek($0) }), in: 0...safeDuration) {
                Text(QTLoc.tr("Time"))
            }
            .disabled(ad != nil)
        }
        .accessibilityValue(ad != nil ? "\(QTLoc.tr("Ad")) \(trailing)" : "\(QTFormat.duration(shownTime)) / \(QTFormat.duration(safeDuration))")
        .accessibilityAdjustableAction { direction in
            guard ad == nil else { return }
            switch direction {
            case .increment: onSeek(min(safeDuration, time + 10))
            case .decrement: onSeek(max(0, time - 10))
            @unknown default: break
            }
        }
        .accessibilityIdentifier(identifier)
    }
}

/// The amber that marks an ad (prototype `#f6c343`): the scrubber's ad progress and its "Ad" label. A deeper amber
/// on light backgrounds so it holds contrast against the bar material; deeper still with Increase Contrast.
public enum QTAdTint {
    public static func color(overArt: Bool = false, increasedContrast: Bool = false) -> Color {
        if overArt { return Color(red: 0.965, green: 0.765, blue: 0.263) }
        return Color(nsColor: NSColor(name: "qt.player.adTint") { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            switch (dark, increasedContrast) {
            case (true, false): return NSColor(srgbRed: 0.965, green: 0.765, blue: 0.263, alpha: 1)
            case (true, true): return NSColor(srgbRed: 1.0, green: 0.82, blue: 0.36, alpha: 1)
            case (false, false): return NSColor(srgbRed: 0.88, green: 0.6, blue: 0.0, alpha: 1)
            case (false, true): return NSColor(srgbRed: 0.68, green: 0.42, blue: 0.0, alpha: 1)
            }
        })
    }
}
