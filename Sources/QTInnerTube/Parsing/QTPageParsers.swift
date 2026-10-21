import Foundation
import QTCore

/// Response → page parsers. Pure functions over `QTJSON`; every one is covered by recorded fixtures in
/// Tests/QTInnerTubeTests.
public enum QTInnerTubeParser {
    // MARK: Home

    public static func home(_ response: QTJSON) -> QTHomePage {
        let sl = QTShelfParser.sectionList(response)
        var moods: [QTMoodChip] = []
        for chip in sl[path: "header", "chipCloudRenderer", "chips"].array {
            let c = chip["chipCloudChipRenderer"]
            guard let title = c["text"].text, case .browse(let id, let params, _)? = c.navigation("navigationEndpoint")
            else { continue }
            if QTParse.isPodcastChip(params: params, title: title) { continue }
            moods.append(QTMoodChip(id: QTBrowseTarget(browseId: id, params: params).moodChipID, title: .verbatim(title)))
        }
        let shelves = QTShelfParser.shelves(response)
        return QTHomePage(feed: QTHomeFeed(moods: moods, shelves: shelves), continuation: QTShelfParser.continuation(sl))
    }

    // MARK: Explore / moods / charts

    public static func explore(_ response: QTJSON) -> QTExplorePage {
        var page = QTExplorePage()
        for (index, section) in QTShelfParser.sections(response).enumerated() {
            let r = section.rendererValue
            let raw = r["items"].array + r["contents"].array
            let buttons = raw.compactMap(QTItemParser.moodButton)
            if !raw.isEmpty, raw.allSatisfy({ $0.rendererKey == "musicNavigationButtonRenderer" }) {
                if section.rendererKey == "gridRenderer" { page.destinations += buttons } else { page.moods += buttons }
                continue
            }
            if let shelf = QTShelfParser.shelf(section, index: index) { page.shelves.append(shelf) }
        }
        return page
    }

    public static func moods(_ response: QTJSON) -> QTMoodsPage {
        var groups: [QTMoodsPage.Group] = []
        for section in QTShelfParser.sections(response) {
            let r = section.rendererValue
            let moods = (r["items"].array + r["contents"].array).compactMap(QTItemParser.moodButton)
            guard !moods.isEmpty else { continue }
            let title = r["header"].rendererValue["title"].text ?? ""
            groups.append(.init(title: title, moods: moods))
        }
        return QTMoodsPage(groups: groups)
    }

    /// Any browse page made of shelves (new releases, charts, a mood/genre page, Related).
    public static func shelves(_ response: QTJSON) -> [QTShelf] {
        QTShelfParser.shelves(response)
    }

    // MARK: Search

    /// `filter` is the filter the request used; unfiltered results carry a type label in each subtitle.
    public static func search(_ response: QTJSON, filter: QTSearchFilter = .all) -> QTSearchResults {
        var results = QTSearchResults()
        let context = QTItemContext(subtitleHasTypeLabel: filter == .all)
        var sections = QTShelfParser.sections(response)
        if let cont = response[path: "continuationContents", "musicShelfContinuation"].object {
            sections.append(["musicShelfRenderer": .object(cont)])
        }
        for section in sections {
            switch section.rendererKey {
            case "musicCardShelfRenderer":
                let card = section["musicCardShelfRenderer"]
                if results.topResult == nil, case .item(let item) = topResult(card) { results.topResult = item }
                var cardItems = QTItemParser.items(card["contents"].array, context: context).items
                // An artist card lists that artist's songs as "Song • 4:45" — no artist run; it's the card's artist.
                if case .artist(let artist)? = results.topResult {
                    cardItems = cardItems.map { item in
                        switch item {
                        case .track(var t) where t.artists.isEmpty:
                            t.artists = [QTArtistRef(id: artist.id, name: artist.name)]
                            return .track(t)
                        case .video(var t) where t.artists.isEmpty:
                            t.artists = [QTArtistRef(id: artist.id, name: artist.name)]
                            return .video(t)
                        default: return item
                        }
                    }
                }
                results.items += cardItems
            case "itemSectionRenderer":
                results.items += QTItemParser.items(section["itemSectionRenderer"]["contents"].array, context: context).items
            case "musicShelfRenderer":
                let shelf = section["musicShelfRenderer"]
                results.items += QTItemParser.items(shelf["contents"].array, context: context).items
                results.continuation = results.continuation ?? QTShelfParser.continuation(shelf)
                    ?? QTShelfParser.continuationItem(shelf["contents"].array)
            default:
                break
            }
        }
        // De-duplicate (the top result can repeat in the list).
        var seen = Set<String>()
        results.items = results.items.filter { seen.insert($0.id).inserted && $0.id != results.topResult?.id }
        // One card per release, and none repeating a top-result album under another id.
        results.items = QTResultTidying.dedupingReleases((results.topResult.map { [$0] } ?? []) + results.items)
            .filter { $0.id != results.topResult?.id }
        return results
    }

    /// The top-result card: same fields as a two-row item, with a type label first in the subtitle.
    static func topResult(_ card: QTJSON) -> QTItemParse {
        let titleRuns = card["title"].runs
        guard let nav = titleRuns.first?.navigation ?? card.navigation("onTap") else { return .unrecognized }
        if QTParse.isNonMusic(nav) { return .nonMusic }
        let subtitle = card["subtitle"].runs
        var groups = subtitle.groups
        if groups.count > 1, groups[0].allSatisfy({ $0.navigation == nil }) { groups.removeFirst() }
        let artwork = QTParse.artwork(card["thumbnail"])
        let title = titleRuns.text
        switch nav {
        case .watch(let videoId, _, _, let mvt):
            let type = QTParse.musicVideoType(mvt)
            var artists = subtitle.artistRefs
            if artists.isEmpty, let g = groups.first { artists = [QTArtistRef(name: g.text)] }
            let duration = groups.lazy.compactMap { QTParse.duration($0.text) }.first ?? 0
            let track = QTTrack(videoId: videoId, title: title, artists: artists, album: subtitle.albumRef,
                                duration: duration, artwork: artwork, musicVideoType: type)
            return .item(QTItemParser.shelfItem(for: track))
        case .browse(let id, _, _):
            switch nav.pageType {
            case .artist: return .item(.artist(QTArtist(id: id, name: title, artwork: artwork)))
            case .album:
                return .item(.album(QTItemParser.album(id: id, title: title, groups: subtitle.groups, runs: subtitle,
                                                       artwork: artwork)))
            case .playlist:
                return .item(.playlist(QTPlaylist(id: id, title: .verbatim(title), kind: QTParse.playlistKind(id),
                                                  owner: groups.first?.text, artwork: artwork)))
            default: return .unrecognized
            }
        default:
            return .unrecognized
        }
    }

    // MARK: Album

    public static func album(_ response: QTJSON, browseId: String) -> QTAlbumPage? {
        let sections = QTShelfParser.sections(response)
        let header = responsiveHeader(response, sections: sections)
        guard let title = header["title"].text else { return nil }
        let subtitle = header["subtitle"].runs
        var album = QTItemParser.album(id: browseId, title: title, groups: subtitle.groups, runs: subtitle,
                                       artwork: QTParse.artwork(header["thumbnail"]))
        let strapline = header["straplineTextOne"].runs
        if !strapline.artistRefs.isEmpty {
            album.artists = strapline.artistRefs
        } else if album.artists.isEmpty, !strapline.isEmpty {
            album.artists = [QTArtistRef(name: strapline.text)]
        }
        let context = QTItemContext(album: QTAlbumRef(id: browseId, title: title), albumArtists: album.artists,
                                    albumArtwork: album.artwork)
        var tracks: [QTTrack] = []
        var shelves: [QTShelf] = []
        for (index, section) in sections.enumerated() {
            if section.rendererKey == "musicShelfRenderer" || section.rendererKey == "musicPlaylistShelfRenderer",
               tracks.isEmpty {
                tracks = QTItemParser.tracks(section.rendererValue["contents"].array, context: context)
            } else if section.rendererKey == "musicCarouselShelfRenderer",
                      let shelf = QTShelfParser.shelf(section, index: index) {
                shelves.append(shelf)
            }
        }
        album.tracks = tracks
        let playlistId = header.all("musicPlayButtonRenderer").lazy.compactMap {
            if case .watchPlaylist(let id, _)? = $0.navigation("playNavigationEndpoint") { id } else { nil }
        }.first ?? canonicalPlaylistId(response)
        return QTAlbumPage(album: album, playlistId: playlistId, summary: header["secondSubtitle"].text,
                           description: header.first("description").flatMap { $0.text }, shelves: shelves,
                           isSaved: savedState(header))
    }

    /// The header's save-to-library toggle (`toggleButtonRenderer` whose action is a `likeEndpoint` on the album's or
    /// playlist's id): `isToggled`, else read from the action, which is the opposite of the current state. nil when
    /// there is none (signed-out pages offer sign-in instead).
    static func savedState(_ header: QTJSON) -> Bool? {
        for toggle in header.all("toggleButtonRenderer") {
            guard let status = toggle[path: "defaultServiceEndpoint", "likeEndpoint", "status"].string else { continue }
            return toggle["isToggled"].bool ?? (status == "INDIFFERENT")
        }
        return nil
    }

    /// The `musicResponsiveHeaderRenderer` (2024+ pages) or legacy detail header.
    static func responsiveHeader(_ response: QTJSON, sections: [QTJSON]) -> QTJSON {
        for s in sections {
            if s.rendererKey == "musicResponsiveHeaderRenderer" { return s["musicResponsiveHeaderRenderer"] }
            if s.rendererKey == "musicEditablePlaylistDetailHeaderRenderer" {
                let inner = s["musicEditablePlaylistDetailHeaderRenderer"][path: "header", "musicResponsiveHeaderRenderer"]
                if !inner.isNull { return inner }
            }
        }
        let legacy = response["header"].rendererValue
        if legacy["title"].text != nil { return legacy }
        return .null
    }

    static func canonicalPlaylistId(_ response: QTJSON) -> String? {
        guard let s = response[path: "microformat", "microformatDataRenderer", "urlCanonical"].string,
              let items = URLComponents(string: s)?.queryItems else { return nil }
        return items.first { $0.name == "list" }?.value
    }

    // MARK: Playlist

    public static func playlist(_ response: QTJSON, browseId: String) -> QTPlaylistPage? {
        let sections = QTShelfParser.sections(response)
        let header = responsiveHeader(response, sections: sections)
        var tracks: [QTTrack] = []
        var continuation: QTContinuation?
        for section in sections where tracks.isEmpty {
            guard section.rendererKey == "musicPlaylistShelfRenderer" || section.rendererKey == "musicShelfRenderer"
            else { continue }
            let shelf = section.rendererValue
            tracks = QTItemParser.tracks(shelf["contents"].array)
            continuation = QTShelfParser.continuationItem(shelf["contents"].array) ?? QTShelfParser.continuation(shelf)
        }
        guard let title = header["title"].text ?? (tracks.isEmpty ? nil : "") else { return nil }
        let owner = header["straplineTextOne"].text
            ?? header[path: "facepile", "avatarStackViewModel", "text", "content"].string
        let summary = header["secondSubtitle"].runs
        let groups = summary.groups
        let count: Int? = groups.count >= 2 ? leadingInteger(groups[groups.count - 2].text) : nil
        let id = browseId == "VLLM" ? "LM" : browseId
        // The account's own playlists come with the editable header (ytmusicapi's `owned`), which also states who can
        // see them; Liked Music is the account's but isn't edited as a playlist.
        let editable = (sections + [response["header"]]).lazy
            .compactMap { $0["musicEditablePlaylistDetailHeaderRenderer"].object.map(QTJSON.object) }.first
        let privacy = editable?[path: "editHeader", "musicPlaylistEditHeaderRenderer", "privacy"].string
            .flatMap(QTPlaylistPrivacy.init(rawValue:))
        // 2024 headers nest it: `description.musicDescriptionShelfRenderer.description.runs`.
        var node = header.first("description")
        for _ in 0..<3 where node != nil && node?.text == nil { node = node?.first("description") }
        let description = node?.text
        let playlist = QTPlaylist(id: id, title: .verbatim(title), kind: QTParse.playlistKind(browseId), owner: owner,
                                  artwork: QTParse.artwork(header["thumbnail"]), tracks: tracks,
                                  isEditable: id == "LM" ? false : editable != nil, privacy: privacy,
                                  description: description)
        return QTPlaylistPage(playlist: playlist, summary: summary.isEmpty ? nil : summary.text,
                              description: description, totalTrackCount: count,
                              continuation: continuation, isSaved: editable == nil ? savedState(header) : nil)
    }

    /// The next page of a playlist / album / library song list.
    public static func trackContinuation(_ response: QTJSON) -> QTTrackPage {
        var items: [QTJSON] = []
        var continuation: QTContinuation?
        for action in response["onResponseReceivedActions"].array {
            let list = action[path: "appendContinuationItemsAction", "continuationItems"].array
            items += list
            continuation = continuation ?? QTShelfParser.continuationItem(list)
        }
        for key in ["musicPlaylistShelfContinuation", "musicShelfContinuation"] {
            let c = response["continuationContents"][key]
            if c.isNull { continue }
            items += c["contents"].array
            continuation = continuation ?? QTShelfParser.continuation(c) ?? QTShelfParser.continuationItem(c["contents"].array)
        }
        return QTTrackPage(tracks: QTItemParser.tracks(items), continuation: continuation)
    }

    static func leadingInteger(_ text: String) -> Int? {
        var digits = ""
        var started = false
        for ch in text {
            if ch.isASCIIDigit {
                digits.append(ch)
                started = true
            } else if started, ch == "," || ch == "." || ch == " " || ch == "\u{00A0}" {
                continue
            } else if started {
                break
            }
        }
        return Int(digits)
    }

    // MARK: Artist

    public static func artist(_ response: QTJSON, browseId: String) -> QTArtistPage? {
        let header = response["header"].rendererValue
        guard let name = header["title"].text else { return nil }
        var page = QTArtistPage(artist: QTArtist(id: browseId, name: name,
                                                 artwork: QTParse.artwork(header["thumbnail"])))
        page.audience = header["monthlyListenerCount"].text
        page.description = header["description"].text
        let subscribe = header[path: "subscriptionButton", "subscribeButtonRenderer"]
        page.channelId = subscribe["channelId"].string
        page.isSubscribed = page.channelId == nil ? nil : subscribe["subscribed"].bool
        var albumShelves = 0
        for (index, section) in QTShelfParser.sections(response).enumerated() {
            switch section.rendererKey {
            case "musicShelfRenderer":
                let r = section["musicShelfRenderer"]
                if page.songs.isEmpty {
                    page.songs = QTItemParser.tracks(r["contents"].array)
                    page.songsPlaylistId = r["title"].runs.first?.navigation?.browseId
                        ?? r.navigation("bottomEndpoint")?.browseId
                }
            case "musicDescriptionShelfRenderer":
                page.description = page.description ?? section.rendererValue["description"].text
            default:
                guard let shelf = QTShelfParser.shelf(section, index: index) else { continue }
                page.shelves.append(shelf)
                let albums = shelf.items.compactMap { if case .album(let a) = $0 { a } else { nil } }
                let videos = shelf.items.compactMap { if case .video(let t) = $0 { t } else { nil } }
                let playlists = shelf.items.compactMap { if case .playlist(let p) = $0 { p } else { nil } }
                let artists = shelf.items.compactMap { if case .artist(let a) = $0 { a } else { nil } }
                if albums.count == shelf.items.count {
                    if albumShelves == 0 { page.albums = albums } else if albumShelves == 1 { page.singles = albums }
                    albumShelves += 1
                } else if videos.count * 2 > shelf.items.count, page.videos.isEmpty {
                    page.videos = videos
                    let header = section.rendererValue["header"].rendererValue
                    page.videosPlaylistId = header["title"].runs.first?.navigation?.browseId
                } else if playlists.count == shelf.items.count {
                    page.playlists += playlists
                } else if artists.count == shelf.items.count, page.relatedArtists.isEmpty {
                    page.relatedArtists = artists
                }
            }
        }
        // Rows on the artist page sometimes omit the artist itself.
        page.songs = page.songs.map { t in
            var t = t
            if t.artists.isEmpty { t.artists = [QTArtistRef(id: browseId, name: name)] }
            return t
        }
        return page
    }

    // MARK: Library

    /// Library pages (`FEmusic_liked_playlists`, `FEmusic_liked_albums`, `FEmusic_library_corpus_track_artists`,
    /// `FEmusic_library_songs`…) and their continuations: every music item in every grid/shelf.
    public static func libraryItems(_ response: QTJSON) -> QTLibraryPage<QTShelfItem> {
        var lists: [QTJSON] = []
        var continuation: QTContinuation?
        for section in QTShelfParser.sections(response) {
            let r = section.rendererValue
            let gridItems = r["items"].array
            let shelfItems = r["contents"].array
            if section.rendererKey == "gridRenderer" || section.rendererKey == "musicShelfRenderer" {
                lists += gridItems + shelfItems
                continuation = continuation ?? QTShelfParser.continuation(r)
                    ?? QTShelfParser.continuationItem(gridItems + shelfItems)
            } else if section.rendererKey == "itemSectionRenderer" {
                for inner in shelfItems where inner.rendererKey == "gridRenderer" || inner.rendererKey == "musicShelfRenderer" {
                    let ir = inner.rendererValue
                    lists += ir["items"].array + ir["contents"].array
                    continuation = continuation ?? QTShelfParser.continuation(ir)
                }
            }
        }
        for key in ["gridContinuation", "musicShelfContinuation"] {
            let c = response["continuationContents"][key]
            if c.isNull { continue }
            let list = c["items"].array + c["contents"].array
            lists += list
            continuation = continuation ?? QTShelfParser.continuation(c) ?? QTShelfParser.continuationItem(list)
        }
        for action in response["onResponseReceivedActions"].array {
            let list = action[path: "appendContinuationItemsAction", "continuationItems"].array
            lists += list
            continuation = continuation ?? QTShelfParser.continuationItem(list)
        }
        return QTLibraryPage(items: QTItemParser.items(lists).items, continuation: continuation)
    }

    // MARK: Watch (next / get_queue / player)

    public static func next(_ response: QTJSON) -> QTWatchNext {
        var result = QTWatchNext()
        let tabs = response[path: "contents", "singleColumnMusicWatchNextResultsRenderer", "tabbedRenderer",
                            "watchNextTabbedResultsRenderer", "tabs"].array
        var panel = tabs.first?[path: "tabRenderer", "content", "musicQueueRenderer", "content", "playlistPanelRenderer"]
            ?? .null
        if panel.isNull { panel = response[path: "continuationContents", "playlistPanelContinuation"] }
        for tab in tabs {
            guard let nav = tab["tabRenderer"].navigation("endpoint"), let id = nav.browseId else { continue }
            if nav.pageType == .trackLyrics || id.hasPrefix("MPLY") { result.lyricsBrowseId = id }
            if nav.pageType == .trackRelated || id.hasPrefix("MPTR") { result.relatedBrowseId = id }
        }
        result.playlistId = panel["playlistId"].string
        for entry in panel["contents"].array {
            if let auto = entry[path: "automixPreviewVideoRenderer", "content", "automixPlaylistVideoRenderer"]
                .navigation("navigationEndpoint"), case .watchPlaylist(let id, let params) = auto {
                result.automix = QTBrowseTarget(browseId: id, params: params)
                continue
            }
            let renderer = entry["playlistPanelVideoRenderer"].isNull
                ? entry[path: "playlistPanelVideoWrapperRenderer", "primaryRenderer", "playlistPanelVideoRenderer"]
                : entry["playlistPanelVideoRenderer"]
            guard case .item(let item) = QTItemParser.parse(entry), let track = item.track else { continue }
            if renderer["selected"].bool == true { result.selectedIndex = result.tracks.count }
            result.tracks.append(track)
        }
        result.continuation = QTShelfParser.continuation(panel)
        return result
    }

    public static func queue(_ response: QTJSON) -> [QTTrack] {
        response["queueDatas"].array.compactMap {
            if case .item(let item) = QTItemParser.parse($0["content"]) { item.track } else { nil }
        }
    }

    public static func player(_ response: QTJSON) -> QTPlayerInfo? {
        let d = response["videoDetails"]
        guard let videoId = d["videoId"].string else { return nil }
        let p = response["playabilityStatus"]
        return QTPlayerInfo(
            videoId: videoId, title: d["title"].string ?? "", author: d["author"].string ?? "",
            channelId: d["channelId"].string, duration: d["lengthSeconds"].double ?? 0,
            musicVideoType: QTParse.musicVideoType(d["musicVideoType"].string),
            artwork: QTParse.artwork(d["thumbnail"]),
            status: QTPlayerInfo.Status(rawValue: p["status"].string ?? "") ?? .unknown,
            reason: p["reason"].string)
    }

    // MARK: Lyrics tab, account

    public static func plainLyrics(_ response: QTJSON) -> QTPlainLyrics? {
        guard let shelf = response.first("musicDescriptionShelfRenderer"),
              let text = shelf["description"].text else { return nil }
        return QTPlainLyrics(text: text, source: shelf["footer"].text)
    }

    public static func account(_ response: QTJSON) -> QTAccountInfo? {
        guard let header = response.first("activeAccountHeaderRenderer"),
              let name = header["accountName"].text else { return nil }
        return QTAccountInfo(name: name, handle: header["channelHandle"].text,
                             photo: QTParse.artwork(header["accountPhoto"]))
    }

    /// Whether YouTube considered the request signed in (`responseContext.serviceTrackingParams` → `logged_in`).
    /// Language-neutral; used for session-loss detection.
    public static func loggedIn(_ response: QTJSON) -> Bool? {
        for service in response[path: "responseContext", "serviceTrackingParams"].array {
            for param in service["params"].array where param["key"].string == "logged_in" {
                return param["value"].string == "1"
            }
        }
        return nil
    }

    public static func visitorData(_ response: QTJSON) -> String? {
        response[path: "responseContext", "visitorData"].string
    }
}
