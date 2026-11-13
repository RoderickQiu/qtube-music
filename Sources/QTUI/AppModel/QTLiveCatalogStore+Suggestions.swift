import Foundation
import QTCore
import QTInnerTube

// Playlist Suggestions (issue #6): the songs YouTube Music lists under one of the account's own playlists, picked
// from what the playlist holds, each with a button that adds it — and Refresh for another set. Signed in only, and
// only for playlists the account owns: YouTube Music sends them as the continuation of the playlist page's section
// list (`QTPlaylistPage.suggestionsContinuation`), one request per playlist per session; Refresh is one more each.
// The demo library offers songs of its own that the playlist doesn't hold yet.

/// One playlist's suggestions as YouTube Music sent them.
public struct QTLivePlaylistSuggestions: Sendable, Hashable {
    /// YouTube Music's heading in the interface language of the request; nil = the app's own "Suggestions".
    public var title: String?
    public var tracks: [QTTrack]
    /// Another set (Refresh). nil = no more to ask for.
    var reload: QTContinuation?
    public var isRefreshing = false

    public var canRefresh: Bool { reload != nil }
}

extension QTLiveCatalogStore {
    /// Rows shown at most (YouTube Music sends 7).
    static let suggestionLimit = 7
    /// The demo library is small: fewer at a time, so Refresh has something else to show.
    static let demoSuggestionLimit = 5

    /// What the page shows under `playlist`: the suggestions it doesn't hold yet, without blocked artists. nil =
    /// no section (not the account's playlist, nothing suggested, or not loaded yet).
    public func suggestions(for playlist: QTPlaylist) -> QTLivePlaylistSuggestions? {
        guard writer.canEdit(playlist), !Self.isMadeHere(playlist.id) else { return nil }
        let held = Set(writer.rows(of: playlist).map(\.videoId))
        let blocklist = model?.artistBlocklist ?? QTArtistBlocklist()
        func shown(_ tracks: [QTTrack]) -> [QTTrack] {
            var seen = held
            return tracks.filter { $0.availability.isPlayable && !blocklist.blocks($0) && seen.insert($0.videoId).inserted }
        }
        if mode == .mock {
            // The demo: songs of the library the playlist doesn't hold, a few at a time.
            let pool = shown(model?.catalog.tracks ?? [])
            guard !held.isEmpty, pool.count > 0 else { return nil }
            let start = (demoSuggestionRounds[playlist.id] ?? 0) * Self.demoSuggestionLimit % pool.count
            let picks = Array((pool[start...] + pool[..<start]).prefix(Self.demoSuggestionLimit))
            return QTLivePlaylistSuggestions(title: nil, tracks: picks,
                                             reload: pool.count > Self.demoSuggestionLimit ? QTContinuation("demo") : nil)
        }
        guard var s = playlistSuggestions[playlist.id] else { return nil }
        s.tracks = Array(shown(s.tracks).prefix(Self.suggestionLimit))
        return s.tracks.isEmpty ? nil : s
    }

    /// Asks once per playlist (a reload of the page keeps the list: songs must not reshuffle under the pointer after
    /// every add). Quiet on failure: the page is whole without the section.
    func loadSuggestions(for id: String, from token: QTContinuation?) {
        guard let token, mode == .live, playlistSuggestions[id] == nil else { return }
        playlistSuggestions[id] = QTLivePlaylistSuggestions(tracks: [], reload: nil, isRefreshing: true)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let answer = try? await client.playlistSuggestions(token)
            guard mode == .live, playlistSuggestions[id] != nil else { return }
            guard let answer else { playlistSuggestions[id] = nil; return }
            remember(answer.tracks)
            playlistSuggestions[id] = QTLivePlaylistSuggestions(title: answer.title, tracks: answer.tracks, reload: answer.reload)
        }
    }

    /// Refresh: another set from YouTube Music (the demo: the next few songs). The old rows stay until the new
    /// ones are here, and stay for good when the request fails. Returns whether new songs arrived.
    @discardableResult
    public func refreshSuggestions(for playlistID: String) async -> Bool {
        if mode == .mock {
            demoSuggestionRounds[playlistID, default: 0] += 1
            return true
        }
        guard mode == .live, let current = playlistSuggestions[playlistID], let token = current.reload,
              !current.isRefreshing else { return false }
        playlistSuggestions[playlistID]?.isRefreshing = true
        let answer = try? await client.playlistSuggestions(token)
        guard mode == .live, playlistSuggestions[playlistID] != nil else { return false }
        playlistSuggestions[playlistID]?.isRefreshing = false
        guard let answer else { return false }
        remember(answer.tracks)
        playlistSuggestions[playlistID] = QTLivePlaylistSuggestions(title: answer.title ?? current.title, tracks: answer.tracks,
                                                                    reload: answer.reload ?? token)
        return true
    }

    /// After a suggestion went into the playlist: when none is left to show, the next set comes by itself (YouTube
    /// Music's `autoReloadWhenEmpty`).
    public func suggestionWasAdded(to playlist: QTPlaylist) {
        guard mode == .live, let raw = playlistSuggestions[playlist.id], !raw.tracks.isEmpty,
              suggestions(for: playlist) == nil else { return }
        Task { await refreshSuggestions(for: playlist.id) }
    }
}
