import AVKit
import QTCore
import SwiftUI

/// Quiet icon button over art, behaving like a toolbar button: glyph only, a soft rounded bezel on hover or when
/// its popover is open, dimmed while pressed. Glyphs at 15 pt (top bar) / 18 pt (bottom row).
struct QTStageChromeButtonStyle: ButtonStyle {
    var isOn = false
    var glyph: CGFloat = 15
    /// A 40 pt circle (for a button that sits on its own glass circle) instead of the 32 pt rounded square.
    var circular = false

    func makeBody(configuration: Configuration) -> some View {
        QTStageChromeButtonBody(configuration: configuration, isOn: isOn, glyph: glyph, circular: circular)
    }
}

private struct QTStageChromeButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isOn: Bool
    let glyph: CGFloat
    let circular: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: glyph, weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(isOn || hovering ? QTTheme.Colors.onArt : QTTheme.Colors.onArt.opacity(contrast == .increased ? 0.9 : 0.72))
            .frame(width: circular ? 40 : 32, height: circular ? 40 : 32)
            .background {
                // On glass the glass itself answers hover; only the on state keeps a fill.
                RoundedRectangle(cornerRadius: circular ? 20 : 8, style: .continuous)
                    .fill(.white.opacity(isOn ? 0.16 : hovering && !circular ? 0.12 : 0))
            }
            .opacity(configuration.isPressed ? 0.6 : isEnabled ? 1 : 0.35)
            .contentShape(Rectangle())
            .onHover { hovering = $0 && isEnabled }
            .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// System AirPlay route picker (AVRoutePickerView), styled to sit with the Stage's glyph buttons.
struct QTStageAirPlayButton: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        view.setRoutePickerButtonColor(NSColor.white.withAlphaComponent(0.72), for: .normal)
        view.setRoutePickerButtonColor(.white, for: .normalHighlighted)
        view.setRoutePickerButtonColor(.white, for: .active)
        view.setAccessibilityIdentifier("qt.stage.airplay")
        // Label and tooltip follow a live language switch.
        view.qtLocalizedAccessibility("AirPlay", toolTip: true)
        return view
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}

/// The Stage's play/pause: a filled white disc with a dark glyph, so the primary action keeps its weight over
/// any background (bright covers, music video). Grows a touch on hover, presses in with a spring; Increase
/// Contrast adds a hairline ring.
struct QTStagePlayButtonStyle: ButtonStyle {
    /// Optical centring for the play triangle (its centroid sits left of its bounding box).
    var glyphOffset: CGFloat = 0

    func makeBody(configuration: Configuration) -> some View {
        QTStagePlayButtonBody(configuration: configuration, glyphOffset: glyphOffset)
    }
}

private struct QTStagePlayButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let glyphOffset: CGFloat
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let diameter: CGFloat = 60

    var body: some View {
        configuration.label
            .labelStyle(.iconOnly)
            .foregroundStyle(Color.black.opacity(0.86))
            .offset(x: glyphOffset)
            .frame(width: diameter, height: diameter)
            .background {
                Circle()
                    .fill(Color.white.opacity(configuration.isPressed ? 0.82 : 1))
                    .shadow(color: .black.opacity(0.28), radius: hovering ? 14 : 10, y: hovering ? 6 : 4)
                    .overlay {
                        if contrast == .increased { Circle().strokeBorder(Color.black.opacity(0.5), lineWidth: 1) }
                    }
            }
            .contentShape(Circle())
            .scaleEffect(reduceMotion ? 1 : configuration.isPressed ? 0.94 : hovering ? 1.04 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovering = $0 && isEnabled }
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8), value: hovering)
    }
}
