import Foundation
import QTCore
import QTInnerTube
import QTPlayback

// Start Radio (docs/architecture.md › Radio): the station YouTube Music would start from a song, album, playlist or
// artist (`QTRadioRequest`), read-only and anonymous-safe — `next` works signed in and as a guest. The station's
// continuation is kept by its playlist id, so Autoplay goes on with the station itself.

/// What a radio starts from: Start Radio in the song, album, artist and playlist menus, Controls and the Dock.
public enum QTRadioSeed: Sendable, Hashable {
    case song(QTTrack)
    /// An album by browse id (`MPREb_…`); `playlistId` is its `OLAK5uy…` list when it is already known.
    case album(id: String, title: String, playlistId: String? = nil)
    /// A playlist or mix by id (`VL…` or raw).
    case playlist(id: String, title: String)
    /// An artist by channel id (`UC…`; library `MPLA…` ids too).
    case artist(id: String, name: String)

    /// What the station is named after ("<title> Radio").
    public var title: String {
        switch self {
        case .song(let t): t.title
        case .album(_, let title, _), .playlist(_, let title): title
        case .artist(_, let name): name
        }
    }

    /// The song a song's radio starts from.
    var song: QTTrack? { if case .song(let t) = self { t } else { nil } }
}

/// A station ready to play: its first tracks (a song's radio starts with that song) and the source it plays from.
public struct QTRadioStation: Sendable, Hashable {
    public var tracks: [QTTrack]
    /// Kind `.radio`, id = the radio's playlist id, title "<seed> Radio".
    public var source: QTQueueSource
}

/// YouTube answered, but with no radio for the seed.
public struct QTRadioUnavailable: Error, Sendable, Hashable {}

extension QTLiveCatalogStore {
    /// Whether Start Radio can start from `seed` here: YouTube Music is browsed (signed in or as a guest, not the demo
    /// library), and the seed is in YouTube's catalog — uploads, local playlists and Liked Music have no radio.
    public func canStartRadio(_ seed: QTRadioSeed) -> Bool {
        guard mode.browsesYouTube else { return false }
        switch seed {
        case .song(let t):
            return t.availability.isPlayable && !t.isPrivatelyOwned && t.videoId.count == 11
        case .album(let id, _, let playlistId):
            return !QTUploads.isAlbumID(id) && (playlistId.map { QTRadioRequest.playlist($0) != nil } ?? true)
        case .playlist(let id, _):
            return QTRadioRequest.playlist(id) != nil
        case .artist(let id, _):
            return !id.isEmpty && !QTUploads.isArtistID(id)
        }
    }

    /// The station for `seed`. Throws the client's error when YouTube can't be reached, `QTRadioUnavailable` when
    /// it has no radio for it. Albums and artists need their page first (cached by the client).
    public func radioStation(for seed: QTRadioSeed) async throws -> QTRadioStation {
        guard canStartRadio(seed) else { throw QTRadioUnavailable() }
        let request: QTRadioRequest
        switch seed {
        case .song(let t):
            request = .song(t.videoId)
        case .playlist(let id, _):
            guard let r = QTRadioRequest.playlist(id) else { throw QTRadioUnavailable() }
            request = r
        case .album(let id, _, let known):
            let playlistId: String?
            if let known { playlistId = known } else if let page = albumPages[id] { playlistId = page.playlistId } else {
                playlistId = try await client.album(id).playlistId
            }
            guard let r = playlistId.flatMap(QTRadioRequest.playlist) else { throw QTRadioUnavailable() }
            request = r
        case .artist(let id, _):
            let page: QTArtistPage
            if let known = artistPages[id] { page = known } else { page = try await client.artist(QTInnerTubeClient.channelId(id)) }
            guard let r = QTRadioRequest.artist(page) else { throw QTRadioUnavailable() }
            request = r
        }
        let page = try await client.radio(request)
        var tracks = page.tracks.filter(\.availability.isPlayable)
        if let song = seed.song {
            // The song it was started from goes first, as the list showed it.
            tracks.removeAll { $0.videoId == song.videoId }
            guard !tracks.isEmpty else { throw QTRadioUnavailable() }
            tracks.insert(song, at: 0)
        }
        guard !tracks.isEmpty else { throw QTRadioUnavailable() }
        radioContinuations[request.playlistId] = page.continuation
        remember(tracks)
        let title = QTLoc.tr("%@ Radio", table: .live, seed.title)
        return QTRadioStation(tracks: tracks, source: QTQueueSource(kind: .radio, id: request.playlistId, title: .verbatim(title)))
    }

    /// Autoplay of a station started here: its own next page (nil when it has none, or for any other source — the
    /// caller then radios from the last song). Network trouble is thrown, so Autoplay's retries ask again with the
    /// same page; a token YouTube no longer takes is dropped.
    func radioContinuation(for request: QTAutoplayRequest) async throws -> [QTTrack]? {
        guard let source = request.source, source.kind == .radio, let id = source.id,
              let token = radioContinuations[id] else { return nil }
        let page: QTWatchNext
        do {
            page = try await client.nextContinuation(token, playlistId: id)
        } catch let error as QTInnerTubeError {
            switch error {
            case .network, .rateLimited, .botCheck: throw error
            default: radioContinuations[id] = nil; return nil
            }
        }
        radioContinuations[id] = page.continuation
        let fresh = page.tracks.filter { !request.excludingVideoIDs.contains($0.videoId) }
        remember(fresh)
        return fresh.isEmpty ? nil : fresh
    }

    #if DEBUG
    /// DEBUG `-qt.live.radio song:<videoId>|album:<browseId>|playlist:<id>|artist:<channelId>`: starts that radio once
    /// YouTube Music is up — cued, not playing, unless `-qt.paused NO` (screenshots of a station in the queue; with
    /// `-qt.live.fixtures YES`, `song:AeXLsAPORb4` answers from the recorded radio and anything else fails offline,
    /// which shows the failure toast).
    func applyLaunchRadio() {
        guard !didApplyLaunchRadio, let model, let arg = model.launch.string("qt.live.radio") else { return }
        let parts = arg.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        didApplyLaunchRadio = true
        let (kind, id) = (parts[0], parts[1])
        let hold = QTReadiness.shared.hold("live.radio")
        Task { @MainActor in
            defer { QTReadiness.shared.release(hold) }
            // After launch playback had its turn (it leaves a queue that is already there alone).
            try? await Task.sleep(for: .seconds(1))
            let seed: QTRadioSeed?
            switch kind {
            case "song": seed = try? await client.next(videoId: id).current.map(QTRadioSeed.song)
            case "album": seed = .album(id: id, title: (try? await client.album(id))?.album.title ?? id)
            case "playlist": seed = .playlist(id: id, title: (try? await client.playlist(id))?.playlist.title.resolved ?? id)
            case "artist": seed = .artist(id: id, name: (try? await client.artist(id))?.artist.name ?? id)
            default: seed = nil
            }
            guard let seed else { return }
            await QTRadioActions.start(seed, autoplay: model.launch.paused == false, store: self, model: model)
        }
    }
    #endif
}
