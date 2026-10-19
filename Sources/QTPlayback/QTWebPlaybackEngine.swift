import Foundation
import QTCore

// Owner: playback builder (M4). Empty on purpose.
//
// Free-account engine: a minimal headless WKWebView running YouTube's own player, ads included, behind a tiny JS
// bridge (load / play / pause / seek / volume / state + ad state). Conforms to `QTPlaybackEngine`.

/// Free-account playback through YouTube's web player.
@MainActor
public final class QTWebPlaybackEngine {
    public init() {}
}
