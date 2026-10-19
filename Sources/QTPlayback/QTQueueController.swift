import Foundation
import QTCore

// Owner: playback builder (M4). Empty on purpose.
//
// Will own the `QTQueue` (QTCore) and the active `QTPlaybackEngine`: start playback from a context, advance on
// `.ended` (Up Next first, then Autoplay; repeat/shuffle policy), fetch more autoplay, persist the queue across
// launches, Song⇄Video switching at the same timestamp. Until then the UI façade `QTPlayerModel` (QTUI) does the
// minimum on its own; when this lands, move that logic here and keep QTPlayerModel's public API.

/// The single owner of the play queue.
@MainActor
public final class QTQueueController {
    public init() {}
}
