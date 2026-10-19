import AppKit
import QTCore
import SwiftUI

// Added by builder "player". One answer to "which glyph marks the current track?" so the track tables, the
// Queue and any later list agree (prototype `window.jsx` `.t-num`): a speaker only while audio is actually
// playing, a pause glyph while paused. Never a speaker for a paused track.

public enum QTNowPlayingIndicator {
    /// SF Symbol for the current track's marker.
    public static func symbolName(isPlaying: Bool) -> String {
        isPlaying ? QTIcon.volume.systemName : QTIcon.pause.systemName
    }

    /// AppKit image for table cells (`NSImageView`), labelled for VoiceOver.
    @MainActor
    public static func image(isPlaying: Bool) -> NSImage? {
        NSImage(systemSymbolName: symbolName(isPlaying: isPlaying),
                accessibilityDescription: QTLoc.tr(isPlaying ? "Now Playing" : "Pause"))
    }
}

/// SwiftUI form of the marker: the speaker's waves pulse gently while playing (off with Reduce Motion).
///
/// An `NSImageView` with an AppKit symbol effect rather than SwiftUI's `.symbolEffect`: SwiftUI re-renders a
/// running variable-colour effect through its display list on every frame (~15 % CPU on a 120 Hz display for one
/// glyph in the Queue), while AppKit hands the effect to Core Animation.
public struct QTNowPlayingGlyph: NSViewRepresentable {
    private let isPlaying: Bool
    private let pointSize: CGFloat
    private let weight: NSFont.Weight
    private let tint: NSColor

    public init(isPlaying: Bool, pointSize: CGFloat = 13, weight: NSFont.Weight = .semibold, tint: NSColor = .white) {
        self.isPlaying = isPlaying
        self.pointSize = pointSize
        self.weight = weight
        self.tint = tint
    }

    public func makeNSView(context: Context) -> QTNowPlayingGlyphView {
        let view = QTNowPlayingGlyphView()
        view.imageScaling = .scaleNone
        view.setAccessibilityElement(false)
        return view
    }

    public func updateNSView(_ view: QTNowPlayingGlyphView, context: Context) {
        view.symbolConfiguration = .init(pointSize: pointSize, weight: weight)
        view.contentTintColor = tint
        view.show(isPlaying: isPlaying, animated: isPlaying && !context.environment.accessibilityReduceMotion)
    }
}

public final class QTNowPlayingGlyphView: NSImageView {
    private var shownName: String?
    private var isAnimating = false

    override public func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(isPlaying: Bool, animated: Bool) {
        let name = QTNowPlayingIndicator.symbolName(isPlaying: isPlaying)
        if name != shownName, let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            removeAllSymbolEffects(animated: false)
            isAnimating = false
            if shownName == nil { image = symbol } else { setSymbolImage(symbol, contentTransition: .replace) }
            shownName = name
        }
        guard animated != isAnimating else { return }
        isAnimating = animated
        if animated {
            addSymbolEffect(.variableColor.iterative.dimInactiveLayers)
        } else {
            removeAllSymbolEffects()
        }
    }
}
