import Foundation
import QTCore

// Owner: playback builder (M4). Empty on purpose.
//
// Will be the *sole* owner of `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter` (media keys, Control Center,
// AirPods). Never let WebKit's mediaSession publish its own entry (Kaset bug #457).

/// The single owner of Now Playing info and remote commands.
@MainActor
public final class QTNowPlayingController {
    public init() {}
}
