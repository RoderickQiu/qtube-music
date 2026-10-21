import Foundation
import QTCore

// Account writes (likes, playlists, subscriptions, saved albums) and the account list, on `QTInnerTubeClient`.
// Endpoints and bodies follow ytmusicapi (MIT, github.com/sigma67/ytmusicapi — mixins/library.py, playlists.py) and
// Kaset (MIT, github.com/sozercan/kaset — YTMusicClient.swift, PlaylistParser.swift, AccountsListParser.swift),
// re-implemented. Every write is refused unless `allowsAccountWrites` is on, needs the session, is sent once (never
// retried, see `perform`), and fails unless YouTube says `STATUS_SUCCEEDED` where it states a status. A successful
// write drops the cached pages it changes.

/// A playlist the account can add to (`playlist/get_add_to_playlist`).
public struct QTPlaylistOption: Sendable, Hashable, Identifiable {
    /// Raw playlist id (`PL…`).
    public var id: String
    public var title: String
    public var privacy: QTPlaylistPrivacy?
    /// Every asked-for video is already in it (the checkmark).
    public var containsVideos: Bool

    public init(id: String, title: String, privacy: QTPlaylistPrivacy? = nil, containsVideos: Bool = false) {
        self.id = id
        self.title = title
        self.privacy = privacy
        self.containsVideos = containsVideos
    }
}

/// A row added to a playlist: its new entry id (what removing or moving it needs).
public struct QTPlaylistAddResult: Sendable, Hashable {
    public var videoId: String
    public var setVideoId: String

    public init(videoId: String, setVideoId: String) {
        self.videoId = videoId
        self.setVideoId = setVideoId
    }
}

/// One identity of the signed-in Google account: the account itself or one of its brand accounts / channels
/// (`account/accounts_list`).
public struct QTAccountIdentity: Sendable, Hashable, Identifiable, Codable {
    /// `brandId`, or "primary" for the Google account itself.
    public var id: String { brandId ?? "primary" }
    public var name: String
    public var handle: String?
    public var photo: [QTArtworkImage]
    /// The 21-digit page id of a brand account (`onBehalfOfUser`); nil for the Google account itself.
    public var brandId: String?
    /// The identity YouTube currently acts as.
    public var isSelected: Bool
    /// YouTube's own account-switch page (`accountSigninToken.signinUrl`, `https://www.youtube.com/signin?…`). It
    /// moves the web session (the player page's identity, `ytcfg.DATASYNC_ID`) to this identity. Never logged.
    public var signinURL: URL?

    public init(name: String, handle: String? = nil, photo: [QTArtworkImage] = [], brandId: String? = nil,
                isSelected: Bool = false, signinURL: URL? = nil) {
        self.name = name
        self.handle = handle
        self.photo = photo
        self.brandId = brandId
        self.isSelected = isSelected
        self.signinURL = signinURL
    }

    public var isPrimary: Bool { brandId == nil }
}

extension QTInnerTubeClient {
    /// What a like / save / unlike sends (`like/like`, `like/dislike`, `like/removelike`).
    public enum QTRating: String, Sendable {
        case like = "like/like", dislike = "like/dislike", none = "like/removelike"
    }

    // MARK: Likes and the library

    /// Likes, dislikes or clears a song.
    public func rate(videoId: String, _ rating: QTRating) async throws {
        _ = try await write(rating.rawValue, body: ["target": ["videoId": .string(videoId)]],
                            invalidating: [QTInnerTube.likedSongsBrowseId, "FEmusic_liked_videos"])
    }

    /// Saves an album (its `OLAK…` playlist) or a playlist to the library (`.like`), or removes it (`.none`).
    public func rate(playlistId: String, _ rating: QTRating) async throws {
        let raw = QTParse.rawPlaylistId(playlistId)
        _ = try await write(rating.rawValue, body: ["target": ["playlistId": .string(raw)]],
                            invalidating: ["FEmusic_liked_playlists", "FEmusic_liked_albums", raw])
    }

    /// Subscribes to an artist's channel (`UC…`), or unsubscribes.
    public func setSubscribed(_ subscribed: Bool, channelId: String) async throws {
        let id = Self.channelId(channelId)
        _ = try await write(subscribed ? "subscription/subscribe" : "subscription/unsubscribe",
                            body: ["channelIds": [.string(id)]],
                            invalidating: ["FEmusic_library_corpus_artists", "FEmusic_library_corpus_track_artists", id])
    }

    // MARK: Playlists

    /// Playlists the account can add `videoIds` to, with whether they already hold them. A read (not cached:
    /// it changes with every add).
    public func addToPlaylistOptions(videoIds: [String]) async throws -> [QTPlaylistOption] {
        let json = try await send("playlist/get_add_to_playlist",
                                  body: ["videoIds": .array(videoIds.map { .string($0) })], requiresAuth: true)
        return QTWriteParser.playlistOptions(json)
    }

    /// Appends songs; returns each new row's entry id. Without `dedupeOption` YouTube refuses songs that are already
    /// in the playlist, so a song is never added twice.
    @discardableResult
    public func addToPlaylist(_ playlistId: String, videoIds: [String]) async throws -> [QTPlaylistAddResult] {
        let actions: [QTJSON] = videoIds.map { ["action": "ACTION_ADD_VIDEO", "addedVideoId": .string($0)] }
        let json = try await editPlaylist(playlistId, actions: actions)
        return QTWriteParser.addResults(json)
    }

    /// `setVideoId` is the row's `playlistSetVideoId`.
    public func removeFromPlaylist(_ playlistId: String, items: [(videoId: String, setVideoId: String)]) async throws {
        let actions: [QTJSON] = items.map {
            ["action": "ACTION_REMOVE_VIDEO", "removedVideoId": .string($0.videoId), "setVideoId": .string($0.setVideoId)]
        }
        _ = try await editPlaylist(playlistId, actions: actions)
    }

    /// Moves the row `setVideoId` in front of the row `successor` (nil = to the end).
    public func movePlaylistItem(_ playlistId: String, setVideoId: String, before successor: String?) async throws {
        var action: [String: QTJSON] = ["action": "ACTION_MOVE_VIDEO_BEFORE", "setVideoId": .string(setVideoId)]
        if let successor { action["movedSetVideoIdSuccessor"] = .string(successor) }
        _ = try await editPlaylist(playlistId, actions: [.object(action)])
    }

    /// Renames a playlist, changes its description or who can see it (nil = unchanged).
    public func editPlaylistDetails(_ playlistId: String, title: String? = nil, description: String? = nil,
                                    privacy: QTPlaylistPrivacy? = nil) async throws {
        var actions: [QTJSON] = []
        if let title { actions.append(["action": "ACTION_SET_PLAYLIST_NAME", "playlistName": .string(title)]) }
        if let description {
            actions.append(["action": "ACTION_SET_PLAYLIST_DESCRIPTION", "playlistDescription": .string(description)])
        }
        if let privacy {
            actions.append(["action": "ACTION_SET_PLAYLIST_PRIVACY", "playlistPrivacy": .string(privacy.rawValue)])
        }
        guard !actions.isEmpty else { return }
        _ = try await editPlaylist(playlistId, actions: actions)
    }

    /// Creates a playlist (optionally with songs); returns its raw id (`PL…`).
    public func createPlaylist(title: String, description: String = "", privacy: QTPlaylistPrivacy = .private,
                               videoIds: [String] = []) async throws -> String {
        var body: [String: QTJSON] = ["title": .string(title), "description": .string(description),
                                      "privacyStatus": .string(privacy.rawValue)]
        if !videoIds.isEmpty { body["videoIds"] = .array(videoIds.map { .string($0) }) }
        let json = try await write("playlist/create", body: body, invalidating: ["FEmusic_liked_playlists"])
        guard let id = QTWriteParser.createdPlaylistId(json) else { throw QTInnerTubeError.parse("playlist/create") }
        return id
    }

    /// Deletes a playlist the account owns. Can't be undone.
    public func deletePlaylist(_ playlistId: String) async throws {
        let raw = QTParse.rawPlaylistId(playlistId)
        _ = try await write("playlist/delete", body: ["playlistId": .string(raw)],
                            invalidating: ["FEmusic_liked_playlists", raw])
    }

    // MARK: Accounts

    /// The Google account and its brand accounts (read-only; never cached — it carries switch links).
    public func accounts() async throws -> [QTAccountIdentity] {
        QTWriteParser.accounts(try await send("account/accounts_list", body: [:], requiresAuth: true))
    }

    // MARK: Plumbing

    private func editPlaylist(_ playlistId: String, actions: [QTJSON]) async throws -> QTJSON {
        let raw = QTParse.rawPlaylistId(playlistId)
        // An edit always states its status; anything but success changed nothing.
        return try await write("browse/edit_playlist", body: ["playlistId": .string(raw), "actions": .array(actions)],
                               requiresStatus: true, invalidating: [raw, "FEmusic_liked_playlists"])
    }

    /// Sends one write (never retried) and checks YouTube's verdict.
    private func write(_ endpoint: String, body: [String: QTJSON], requiresStatus: Bool = false,
                       invalidating needles: [String]) async throws -> QTJSON {
        let json = try await send(endpoint, body: body, requiresAuth: true)
        if let status = json["status"].string {
            guard status == "STATUS_SUCCEEDED" else { throw QTInnerTubeError.writeRejected(status: status) }
        } else if requiresStatus {
            throw QTInnerTubeError.writeRejected(status: "none")
        }
        invalidateCache(mentioning: needles)
        return json
    }
}

/// Parsers for write answers and the account list. Pure functions over `QTJSON`.
public enum QTWriteParser {
    /// New entry ids from an `edit_playlist` add (`playlistEditResults[].playlistEditVideoAddedResultData`).
    public static func addResults(_ json: QTJSON) -> [QTPlaylistAddResult] {
        json["playlistEditResults"].array.compactMap {
            let d = $0["playlistEditVideoAddedResultData"]
            guard let v = d["videoId"].string, let s = d["setVideoId"].string else { return nil }
            return QTPlaylistAddResult(videoId: v, setVideoId: s)
        }
    }

    /// `playlist/create`'s new id: `playlistId` at the top, else the first playlist the answer links to.
    public static func createdPlaylistId(_ json: QTJSON) -> String? {
        if let id = json["playlistId"].string, !id.isEmpty { return QTParse.rawPlaylistId(id) }
        if let id = json.first("playlistId")?.string, !id.isEmpty { return QTParse.rawPlaylistId(id) }
        return json.all("browseId").lazy.compactMap(\.string).first { $0.hasPrefix("VL") }.map(QTParse.rawPlaylistId)
    }

    /// The add-to-playlist dialog: one option per playlist (first wins), "New playlist" rows skipped.
    public static func playlistOptions(_ json: QTJSON) -> [QTPlaylistOption] {
        var seen = Set<String>()
        var out: [QTPlaylistOption] = []
        for key in ["playlistAddToOptionRenderer", "addToPlaylistItemRenderer"] {
            for r in json.all(key) {
                guard let option = option(r), seen.insert(option.id).inserted else { continue }
                out.append(option)
            }
        }
        return out
    }

    static func option(_ r: QTJSON) -> QTPlaylistOption? {
        let id = r["playlistId"].string ?? r.first("playlistEditEndpoint")?["playlistId"].string
            ?? r.first("playlistId")?.string
        guard let id, !id.isEmpty, let title = r["title"].text ?? r["text"].text else { return nil }
        // "ALL" / "SOME" / "NONE" (YouTube's dialog), or a selected / checked flag.
        let contains = r["containsSelectedVideos"].string.map { $0 == "ALL" }
            ?? r["selected"].bool ?? r["isSelected"].bool ?? r["checked"].bool ?? false
        let privacyText = (r["privacy"].string ?? r["privacyStatus"].string
            ?? r.first("privacyIcon")?["iconType"].string ?? "").uppercased()
        let privacy = QTPlaylistPrivacy.allCases.first { privacyText.contains($0.rawValue) }
        return QTPlaylistOption(id: QTParse.rawPlaylistId(id), title: title, privacy: privacy, containsVideos: contains)
    }

    /// `account/accounts_list` → `actions[0].getMultiPageMenuAction.menu.multiPageMenuRenderer.sections[]
    /// .accountSectionListRenderer.contents[].accountItemSectionRenderer.contents[].accountItem`.
    public static func accounts(_ json: QTJSON) -> [QTAccountIdentity] {
        json.all("accountItem").compactMap { item in
            guard let name = item["accountName"].text else { return nil }
            var brandId: String?
            var signin: URL?
            for token in item[path: "serviceEndpoint", "selectActiveIdentityEndpoint", "supportedTokens"].array {
                if brandId == nil, let id = token[path: "pageIdToken", "pageId"].string, !id.isEmpty { brandId = id }
                if signin == nil, let s = token[path: "accountSigninToken", "signinUrl"].string { signin = signinURL(s) }
            }
            return QTAccountIdentity(name: name, handle: item["channelHandle"].text,
                                     photo: QTParse.artwork(item["accountPhoto"]), brandId: brandId,
                                     isSelected: item["isSelected"].bool ?? false, signinURL: signin)
        }
    }

    /// The switch link resolved against www.youtube.com; only `https://www.youtube.com/signin` is ever accepted.
    public static func signinURL(_ string: String) -> URL? {
        let url: URL?
        if string.hasPrefix("https://") || string.hasPrefix("http://") {
            url = URL(string: string)
        } else if string.hasPrefix("//") {
            url = URL(string: "https:" + string)
        } else {
            url = URL(string: string, relativeTo: URL(string: "https://www.youtube.com"))?.absoluteURL
        }
        guard let url, isAllowedSigninURL(url) else { return nil }
        return url
    }

    public static func isAllowedSigninURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "www.youtube.com" && url.path == "/signin"
    }

    /// Whether a page's `ytcfg.DATASYNC_ID` shows `brandId` (nil = the Google account itself) as the active
    /// identity: `"<delegated>||<user>"` for a brand account, `"<user>||"` for the account itself. Blank or malformed
    /// values (the page hasn't set `ytcfg` yet) match neither.
    public static func dataSyncId(_ value: String, matches brandId: String?) -> Bool {
        let parts = value.components(separatedBy: "||")
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let delegated: String? = parts[1].isEmpty ? nil : parts[0]
        return delegated == brandId
    }
}
