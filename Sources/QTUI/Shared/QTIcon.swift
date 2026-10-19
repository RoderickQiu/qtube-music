import SwiftUI

/// The prototype's icon set (design/prototype/icons.jsx) mapped to SF Symbols. Use `QTIcon.x.image` or
/// `Label(text, systemImage: QTIcon.x.systemName)`. Prefer `.symbolRenderingMode(.hierarchical)` for multi-layer glyphs.
public enum QTIcon: String, CaseIterable, Sendable {
    case play, pause, next, prev, shuffle, `repeat`, repeatOne
    case heart, heartFill
    case home, compass, note, album, mic, clock, list, playlist
    case search, chevL, chevR, chevD, chevU
    case expand, mini, lyrics, volume, volumeMuted, airplay, more, sidebar
    case grip, video, check, layers, close, sparkle, pin

    public var systemName: String {
        switch self {
        case .play: "play.fill"
        case .pause: "pause.fill"
        case .next: "forward.fill"
        case .prev: "backward.fill"
        case .shuffle: "shuffle"
        case .repeat: "repeat"
        case .repeatOne: "repeat.1"
        case .heart: "heart"
        case .heartFill: "heart.fill"
        case .home: "house"
        case .compass: "safari"
        case .note: "music.note"
        case .album: "square.stack"
        case .mic: "music.microphone"
        case .clock: "clock"
        case .list: "list.bullet"
        case .playlist: "music.note.list"
        case .search: "magnifyingglass"
        case .chevL: "chevron.left"
        case .chevR: "chevron.right"
        case .chevD: "chevron.down"
        case .chevU: "chevron.up"
        case .expand: "arrow.up.left.and.arrow.down.right"
        case .mini: "pip"
        case .lyrics: "quote.bubble"
        case .volume: "speaker.wave.2.fill"
        case .volumeMuted: "speaker.slash.fill"
        case .airplay: "airplay.audio"
        case .more: "ellipsis"
        case .sidebar: "sidebar.trailing"
        case .grip: "line.3.horizontal"
        case .video: "play.rectangle"
        case .check: "checkmark"
        case .layers: "square.3.layers.3d"
        case .close: "xmark"
        case .sparkle: "paintpalette"
        case .pin: "pin"
        }
    }

    public var image: Image { Image(systemName: systemName) }
}
