import Foundation
import LyricsKit

// LyricsKit (MxIris fork, MPL-2.0) is linked here so the lyrics builder never has to touch Package.swift.
// It is built in Swift 5 language mode; wrap its types at this boundary and convert to QTLyricsDocument,
// never leak LyricsKit types out of QTLyrics.

/// Namespace for the LyricsKit adapter (lyrics builder fills this in).
enum QTLyricsKitBridge {
    /// LyricsKit's lyrics model, re-exported internally for the adapter.
    typealias KitLyrics = Lyrics
}
