import QTCore
import SwiftUI

// Owner: builder "playback" (Shared/: add-only). The play button's "waiting for media" state.

private struct QTBufferingIndicatorModifier: ViewModifier {
    let isBuffering: Bool
    let controlSize: ControlSize
    /// Debounced: quick loads (most track changes) never flash a spinner.
    @State private var isShown = false

    func body(content: Content) -> some View {
        content
            .opacity(isShown ? 0 : 1)
            .overlay {
                if isShown {
                    ProgressView()
                        .controlSize(controlSize)
                        .transition(.opacity)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityValue(isShown ? QTLoc.tr("Loading", table: .playback) : "")
            .task(id: isBuffering) {
                if isBuffering {
                    try? await Task.sleep(for: .milliseconds(450))
                    guard !Task.isCancelled else { return }
                }
                withAnimation(.easeOut(duration: 0.18)) { isShown = isBuffering }
            }
    }
}

public extension View {
    /// Swaps the view for a system spinner while `isBuffering` stays true for more than ~0.45 s.
    func qtBufferingIndicator(_ isBuffering: Bool, controlSize: ControlSize = .small) -> some View {
        modifier(QTBufferingIndicatorModifier(isBuffering: isBuffering, controlSize: controlSize))
    }
}
