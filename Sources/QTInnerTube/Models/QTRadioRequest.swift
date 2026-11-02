import Foundation

/// The `next` request that starts a YouTube Music radio (Start Radio), shaped as YouTube Music's own menus send it:
/// a song's radio is `RDAMVM<videoId>` with that song first; a playlist's or album's is `RDAMPL<playlistId>` (an
/// album radios through its `OLAK5uy…` playlist); an artist's is the mix their page's header offers (`RDEM…`, with
/// the video it starts from). `params` is the radio flag the web client sends with every one of them.
public struct QTRadioRequest: Sendable, Hashable {
    /// The song the radio starts from (songs and artists); nil for a playlist's radio.
    public var videoId: String?
    /// The radio's own playlist id (`RDAMVM…`, `RDAMPL…`, `RDEM…`): also what its continuation and the queue's
    /// Autoplay source are keyed by.
    public var playlistId: String
    public var params: String?

    /// YouTube Music's "start radio" `params` (its menus' Start mix / Start radio endpoints).
    public static let radioParams = "wAEB"

    public init(videoId: String? = nil, playlistId: String, params: String? = QTRadioRequest.radioParams) {
        self.videoId = videoId
        self.playlistId = playlistId
        self.params = params
    }

    /// A song's radio, that song first.
    public static func song(_ videoId: String) -> QTRadioRequest {
        QTRadioRequest(videoId: videoId, playlistId: "RDAMVM" + videoId)
    }

    /// A playlist's radio (`VL…` browse ids and raw ids alike); an album's, given its `OLAK5uy…` playlist. A mix is
    /// already a radio: it plays itself. nil for lists YouTube has no radio for: Liked Music and lists that only
    /// exist on this Mac or are still being created.
    public static func playlist(_ id: String) -> QTRadioRequest? {
        let raw = QTParse.rawPlaylistId(id)
        guard !raw.isEmpty, raw != "LM", !raw.contains(":") else { return nil }
        if QTParse.playlistKind(raw) == .mix { return QTRadioRequest(playlistId: raw) }
        return QTRadioRequest(playlistId: "RDAMPL" + raw)
    }

    /// An artist's radio: the mix the page's header offers, else the radio of their first top song.
    public static func artist(_ page: QTArtistPage) -> QTRadioRequest? {
        if let radio = page.radio { return radio }
        return page.songs.first { $0.availability.isPlayable && !$0.isPrivatelyOwned }.map { song($0.videoId) }
    }
}
