import AppKit
import AVKit
import QTCore
import SwiftUI

// Owner: builder "player". The system AirPlay route picker (AVRoutePickerView), borderless like the other
// player-bar tools. Clicking it opens the system's own route menu.

/// AirPlay output picker for the player bar.
public struct QTAirPlayButton: NSViewRepresentable {
    private let overArt: Bool

    public init(overArt: Bool = false) {
        self.overArt = overArt
    }

    public func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        view.setAccessibilityIdentifier("qt.player.airplay")
        // Label and tooltip follow a live language switch (updateNSView alone isn't called for it).
        view.qtLocalizedAccessibility("AirPlay", toolTip: true)
        apply(to: view)
        return view
    }

    public func updateNSView(_ view: AVRoutePickerView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: AVRoutePickerView) {
        let normal: NSColor = overArt ? .white.withAlphaComponent(0.72) : .secondaryLabelColor
        let active: NSColor = overArt ? .white : .controlAccentColor
        view.setRoutePickerButtonColor(normal, for: .normal)
        view.setRoutePickerButtonColor(overArt ? .white : .labelColor, for: .normalHighlighted)
        view.setRoutePickerButtonColor(active, for: .active)
        view.setRoutePickerButtonColor(active, for: .activeHighlighted)
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: AVRoutePickerView, context: Context) -> CGSize? {
        CGSize(width: 28, height: 28)
    }
}
