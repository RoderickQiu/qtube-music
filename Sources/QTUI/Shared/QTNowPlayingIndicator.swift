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
public struct QTNowPlayingGlyph: View {
    private let isPlaying: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(isPlaying: Bool) {
        self.isPlaying = isPlaying
    }

    public var body: some View {
        Image(systemName: QTNowPlayingIndicator.symbolName(isPlaying: isPlaying))
            .symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: isPlaying && !reduceMotion)
            .contentTransition(.symbolEffect(.replace))
            .accessibilityHidden(true)
    }
}
