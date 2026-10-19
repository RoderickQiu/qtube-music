import AVKit
import QTCore
import SwiftUI

/// Quiet icon button over art, behaving like a toolbar button: glyph only, a soft rounded bezel on hover or when
/// its popover is open, dimmed while pressed. Glyphs at 15 pt (top bar) / 18 pt (bottom row).
struct QTStageChromeButtonStyle: ButtonStyle {
    var isOn = false
    var glyph: CGFloat = 15

    func makeBody(configuration: Configuration) -> some View {
        QTStageChromeButtonBody(configuration: configuration, isOn: isOn, glyph: glyph)
    }
}

private struct QTStageChromeButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isOn: Bool
    let glyph: CGFloat
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: glyph, weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(isOn || hovering ? QTTheme.Colors.onArt : QTTheme.Colors.onArt.opacity(contrast == .increased ? 0.9 : 0.72))
            .frame(width: 32, height: 32)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(isOn ? 0.16 : hovering ? 0.12 : 0))
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
        view.setAccessibilityLabel(QTLoc.tr("AirPlay"))
        view.setAccessibilityIdentifier("qt.stage.airplay")
        view.toolTip = QTLoc.tr("AirPlay")
        return view
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}
