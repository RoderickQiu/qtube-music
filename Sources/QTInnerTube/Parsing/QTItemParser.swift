import Foundation
import QTCore

/// Context that list rows inherit from the page they are on.
struct QTItemContext: Sendable {
    /// Top-level search rows start their subtitle with a localized type label ("Song • HKT", "歌曲 • 周杰倫").
    var subtitleHasTypeLabel = false
    /// Album pages omit the album, artists and artwork on each row.
    var album: QTAlbumRef?
    var albumArtists: [QTArtistRef] = []
    var albumArtwork: [QTArtworkImage] = []
    /// Rows of the uploads library and its album / artist pages: every song on them is the user's own upload.
    var privatelyOwned = false

    static let plain = QTItemContext()
}

/// Result of parsing one renderer.
enum QTItemParse: Sendable {
    case item(QTShelfItem)
    /// A podcast, episode, profile… dropped by the music-only filter.
    case nonMusic
    /// Not an item renderer we understand (dividers, chips, continuation items).
    case unrecognized
}

/// Parses individual item renderers (`musicResponsiveListItemRenderer`, `musicTwoRowItemRenderer`,
/// `playlistPanelVideoRenderer`, `musicNavigationButtonRenderer`…) into QTCore models.
enum QTItemParser {
    static func parse(_ wrapper: QTJSON, context: QTItemContext = .plain) -> QTItemParse {
        guard let key = wrapper.rendererKey else { return .unrecognized }
        let r = wrapper[key]
        switch key {
        case "musicResponsiveListItemRenderer": return listItem(r, context: context)
        case "musicTwoRowItemRenderer": return twoRowItem(r)
        case "playlistPanelVideoRenderer": return panelVideo(r).map { .item(shelfItem(for: $0)) } ?? .unrecognized
        case "playlistPanelVideoWrapperRenderer":
            return panelWrapper(r).map { .item(shelfItem(for: $0)) } ?? .unrecognized
        case "musicMultiRowListItemRenderer":
            // Podcast episodes (Explore › "Popular episodes"). Never music.
            return .nonMusic
        default:
            return .unrecognized
        }
    }

    /// Items of a list, music only, in order.
    static func items(_ list: [QTJSON], context: QTItemContext = .plain) -> (items: [QTShelfItem], nonMusic: Int) {
        var items: [QTShelfItem] = []
        var nonMusic = 0
        for entry in list {
            switch parse(entry, context: context) {
            case .item(let i): items.append(i)
            case .nonMusic: nonMusic += 1
            case .unrecognized: break
            }
        }
        return (items, nonMusic)
    }

    static func tracks(_ list: [QTJSON], context: QTItemContext = .plain) -> [QTTrack] {
        items(list, context: context).items.compactMap(\.track)
    }

    static func shelfItem(for track: QTTrack) -> QTShelfItem {
        track.musicVideoType.isVideo ? .video(track) : .track(track)
    }

    // MARK: musicResponsiveListItemRenderer

    static func listItem(_ r: QTJSON, context: QTItemContext) -> QTItemParse {
        let columns: [[QTRun]] = r["flexColumns"].array.map {
            $0[path: "musicResponsiveListItemFlexColumnRenderer", "text"].runs
        }
        let fixed: [[QTRun]] = r["fixedColumns"].array.map {
            $0[path: "musicResponsiveListItemFixedColumnRenderer", "text"].runs
        }
        let titleRuns = columns.first ?? []
        let title = titleRuns.text
        let overlayNav = r[path: "overlay", "musicItemThumbnailOverlayRenderer", "content", "musicPlayButtonRenderer"]
            .navigation("playNavigationEndpoint")
        let itemNav = r.navigation("navigationEndpoint")
        let titleNav = titleRuns.first?.navigation
        // A greyed-out row (not available here, removed) may come without any playable id: it stays in the list as a
        // greyed row, like on YouTube Music, so playlist and Liked counts agree with it.
        // Upload rows may link nothing to play but their menu's "Add to queue" (ytmusicapi `parse_uploaded_items`).
        let videoId = r[path: "playlistItemData", "videoId"].string ?? titleNav?.videoId ?? overlayNav?.videoId
            ?? itemNav?.videoId
            ?? (availability(r).isPlayable ? QTParse.queueAddVideoId(menu: r["menu"]) : unavailableRowID(r, title: title))

        let primaryNav: QTNavigation? = {
            if let itemNav, case .browse = itemNav { return itemNav }
            if let titleNav, case .browse = titleNav { return titleNav }
            return titleNav ?? itemNav ?? overlayNav
        }()

        if QTParse.isNonMusic(primaryNav) || QTParse.isNonMusic(titleNav) || QTParse.isNonMusic(overlayNav) {
            return .nonMusic
        }
        let artwork = QTParse.artwork(r["thumbnail"])
        // Second line: column 1 (artist • album • duration…); later columns carry plays/album.
        let subtitleRuns = columns.dropFirst().flatMap { $0 + [QTRun(text: " • ")] }
        var groups = (columns.count > 1 ? columns[1] : []).groups
        if context.subtitleHasTypeLabel, groups.count > 1, groups[0].allSatisfy({ $0.navigation == nil }) {
            groups.removeFirst()
        }

        if let videoId, primaryNav?.browseId == nil || primaryNav?.videoId != nil {
            guard !title.isEmpty else { return .unrecognized }
            let mvtRaw = titleNav?.musicVideoTypeRaw ?? overlayNav?.musicVideoTypeRaw ?? itemNav?.musicVideoTypeRaw
            let type = QTParse.musicVideoType(mvtRaw)
            if type == .other, mvtRaw != nil { return .nonMusic }
            var artists = subtitleRuns.artistRefs
            // Unlinked artist (uploads, some search rows): the first group of the second line, after any label.
            if artists.isEmpty, let first = groups.first, first.allSatisfy({ $0.navigation == nil }),
               QTParse.duration(first.text) == nil {
                artists = [QTArtistRef(name: first.text)]
            }
            if artists.isEmpty { artists = context.albumArtists }
            let duration = (fixed.map(\.text) + groups.map(\.text)).lazy.compactMap(QTParse.duration).first ?? 0
            var track = QTTrack(
                videoId: videoId, title: title, artists: artists,
                album: subtitleRuns.albumRef ?? context.album, duration: duration,
                artwork: artwork.isEmpty ? context.albumArtwork : artwork, musicVideoType: type,
                isExplicit: isExplicit(r), availability: availability(r),
                setVideoId: setVideoId(r), likeStatus: likeStatus(menu: r["menu"]),
                isPrivatelyOwned: context.privatelyOwned || mvtRaw == QTParse.privatelyOwnedType
                    || QTParse.hasDeleteUploadCommand(menu: r["menu"]))
            if type.isVideo, let audioId = QTParse.creditsVideoId(menu: r["menu"]), audioId != videoId {
                track.counterpart = QTCounterpart(videoId: audioId, musicVideoType: .atv)
            }
            return .item(shelfItem(for: track))
        }

        guard let nav = primaryNav, let browseId = nav.browseId, !title.isEmpty else { return .unrecognized }
        switch nav.pageType {
        case .album:
            return .item(.album(album(id: browseId, title: title, groups: (columns.count > 1 ? columns[1] : []).groups,
                                      runs: subtitleRuns, artwork: artwork)))
        case .artist, .libraryArtist:
            return .item(.artist(QTArtist(id: browseId, name: title, artwork: artwork)))
        case .playlist:
            let owner = playlistOwner(groups)
            return .item(.playlist(QTPlaylist(id: browseId, title: .verbatim(title), kind: QTParse.playlistKind(browseId),
                                              owner: owner, artwork: artwork)))
        default:
            return .unrecognized
        }
    }

    // MARK: musicTwoRowItemRenderer

    static func twoRowItem(_ r: QTJSON) -> QTItemParse {
        guard let title = r["title"].text else { return .unrecognized }
        let nav = r.navigation("navigationEndpoint") ?? r["title"].runs.first?.navigation
        if QTParse.isNonMusic(nav) { return .nonMusic }
        let subtitle = r["subtitle"].runs
        let artwork = QTParse.artwork(r["thumbnailRenderer"])
        switch nav {
        case .watch(let videoId, _, _, let mvt)?:
            let type = QTParse.musicVideoType(mvt)
            if type == .other, mvt != nil { return .nonMusic }
            var artists = subtitle.artistRefs
            let groups = subtitle.groups
            if artists.isEmpty, let first = groups.first(where: { !QTParse.isStatistic($0.text) }) {
                // "Video • Artist • 1M views" vs "Artist • 1M views": the artist is the last non-statistic group.
                let candidates = groups.filter { !QTParse.isStatistic($0.text) }
                artists = [QTArtistRef(name: (candidates.count > 1 ? candidates.last! : first).text)]
            }
            let duration = groups.lazy.compactMap { QTParse.duration($0.text) }.first ?? 0
            let track = QTTrack(videoId: videoId, title: title, artists: artists, album: subtitle.albumRef,
                                duration: duration, artwork: artwork, musicVideoType: type,
                                isExplicit: isExplicit(r), isPrivatelyOwned: mvt == QTParse.privatelyOwnedType)
            return .item(shelfItem(for: track))
        case .watchPlaylist(let playlistId, _)?:
            return .item(.playlist(QTPlaylist(id: QTParse.playlistBrowseId(playlistId), title: .verbatim(title),
                                              kind: .mix, owner: nil, artwork: artwork)))
        case .browse(let browseId, _, _)?:
            switch nav?.pageType {
            case .album:
                return .item(.album(album(id: browseId, title: title, groups: subtitle.groups, runs: subtitle,
                                          artwork: artwork)))
            case .artist, .libraryArtist:
                return .item(.artist(QTArtist(id: browseId, name: title, artwork: artwork)))
            case .playlist:
                var groups = subtitle.groups
                // "Playlist • Owner • 1M views": drop a leading label (an unlinked group followed by a non-statistic).
                if groups.count >= 2, groups[0].allSatisfy({ $0.navigation == nil }), !QTParse.isStatistic(groups[1].text) {
                    groups.removeFirst()
                }
                let owner = playlistOwner(groups)
                return .item(.playlist(QTPlaylist(id: browseId, title: .verbatim(title),
                                                  kind: QTParse.playlistKind(browseId), owner: owner, artwork: artwork)))
            default:
                return .unrecognized
            }
        default:
            return .unrecognized
        }
    }

    // MARK: Albums

    static func album(id: String, title: String, groups: [[QTRun]], runs: [QTRun], artwork: [QTArtworkImage]) -> QTAlbum {
        var kind: QTAlbumKind = .album
        var year: Int?
        var artists = runs.artistRefs
        var rest = groups
        if let first = rest.first, first.allSatisfy({ $0.navigation == nil }), let k = QTParse.albumKind(label: first.text) {
            kind = k
            rest.removeFirst()
        }
        for g in rest {
            if let y = QTParse.year(g.text) { year = y }
        }
        if artists.isEmpty, let g = rest.first(where: { QTParse.year($0.text) == nil && !QTParse.isStatistic($0.text) }) {
            artists = [QTArtistRef(name: g.text)]
        }
        return QTAlbum(id: id, title: title, artists: artists, year: year, kind: kind, artwork: artwork)
    }

    /// Owner of a playlist from its subtitle groups (label already removed): a linked channel, else the first group
    /// unless it's the only one and a statistic ("5 views").
    static func playlistOwner(_ groups: [[QTRun]]) -> String? {
        if let linked = groups.first(where: { $0.contains { $0.navigation != nil } }) { return linked.text }
        guard let first = groups.first else { return nil }
        if groups.count == 1, QTParse.isStatistic(first.text) { return nil }
        return first.text
    }

    // MARK: Badges / availability

    static func isExplicit(_ r: QTJSON) -> Bool {
        (r["badges"].array + r["subtitleBadges"].array).contains {
            $0[path: "musicInlineBadgeRenderer", "icon", "iconType"].string == "MUSIC_EXPLICIT_BADGE"
        }
    }

    /// A stable id for a greyed-out row without a playable video id: the video id its menu still names, else the
    /// playlist entry id, else its title. Never well-formed as a video id, so nothing tries to play it.
    static func unavailableRowID(_ r: QTJSON, title: String) -> String? {
        guard !title.isEmpty else { return nil }
        let menuID = r["menu"].first("removedVideoId")?.string ?? r["menu"].first("videoId")?.string
        let entry = r[path: "playlistItemData", "playlistSetVideoId"].string
        return "unavailable:" + (menuID ?? entry ?? title)
    }

    /// A playlist row's entry id: `playlistItemData.playlistSetVideoId`, else the one its "Remove from playlist" menu
    /// item names (`playlistEditEndpoint.actions[0].setVideoId`, as ytmusicapi reads it).
    static func setVideoId(_ r: QTJSON) -> String? {
        if let id = r[path: "playlistItemData", "playlistSetVideoId"].string, !id.isEmpty { return id }
        for endpoint in r["menu"].all("playlistEditEndpoint") {
            if let id = endpoint["actions"].array.lazy.compactMap({ $0["setVideoId"].string }).first { return id }
        }
        return nil
    }

    /// The account's like for a row: the menu's like button (`likeButtonRenderer.likeStatus`), else its like toggle,
    /// whose default action is the *opposite* of the current state (ytmusicapi `parse_like_status`).
    static func likeStatus(menu: QTJSON) -> QTLikeStatus? {
        if let raw = menu.first("likeButtonRenderer")?["likeStatus"].string { return QTLikeStatus(rawValue: raw) }
        for toggle in menu.all("toggleMenuServiceItemRenderer") {
            switch toggle[path: "defaultServiceEndpoint", "likeEndpoint", "status"].string {
            case "LIKE"?: return .indifferent
            case "INDIFFERENT"?: return .like
            default: continue
            }
        }
        return nil
    }

    static func availability(_ r: QTJSON) -> QTAvailability {
        r["musicItemRendererDisplayPolicy"].string == "MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT" ? .regionLocked
            : .playable
    }

    // MARK: Queue rows (next / get_queue)

    /// A `playlistPanelVideoRenderer` (Up Next / autoplay rows).
    static func panelVideo(_ r: QTJSON) -> QTTrack? {
        guard let videoId = r["videoId"].string, let title = r["title"].text else { return nil }
        let nav = r.navigation("navigationEndpoint")
        if QTParse.isNonMusic(nav) { return nil }
        let byline = r["longBylineText"].runs
        let groups = byline.groups
        var artists = byline.artistRefs
        if artists.isEmpty, let first = groups.first {
            artists = [QTArtistRef(name: first.text)]
        }
        let type = QTParse.musicVideoType(nav?.musicVideoTypeRaw)
        var track = QTTrack(
            videoId: videoId, title: title, artists: artists, album: byline.albumRef,
            duration: r["lengthText"].text.flatMap(QTParse.duration) ?? 0,
            artwork: QTParse.artwork(r["thumbnail"]), musicVideoType: type,
            isExplicit: isExplicit(r), likeStatus: likeStatus(menu: r["menu"]),
            isPrivatelyOwned: nav?.musicVideoTypeRaw == QTParse.privatelyOwnedType)
        if type.isVideo, let audioId = QTParse.creditsVideoId(menu: r["menu"]), audioId != videoId {
            track.counterpart = QTCounterpart(videoId: audioId, musicVideoType: .atv)
        }
        return track
    }

    /// A `playlistPanelVideoWrapperRenderer`: the primary rendition plus its Song⇄Video counterpart
    /// (`counterpart[0].counterpartRenderer.playlistPanelVideoRenderer`, shape as in ytmusicapi's watch parser).
    static func panelWrapper(_ r: QTJSON) -> QTTrack? {
        guard var primary = panelVideo(r[path: "primaryRenderer", "playlistPanelVideoRenderer"]) else { return nil }
        if let other = r["counterpart"].array.lazy.compactMap({
            panelVideo($0[path: "counterpartRenderer", "playlistPanelVideoRenderer"])
        }).first, other.videoId != primary.videoId {
            primary.counterpart = QTCounterpart(videoId: other.videoId, musicVideoType: other.musicVideoType,
                                                artwork: other.artwork)
        }
        return primary
    }

    // MARK: Mood / genre buttons

    static func moodButton(_ wrapper: QTJSON) -> QTMoodChip? {
        let r = wrapper["musicNavigationButtonRenderer"]
        guard let title = r["buttonText"].text, let nav = r.navigation("clickCommand"), !QTParse.isNonMusic(nav),
              case .browse(let id, let params, _) = nav else { return nil }
        return QTMoodChip(id: QTBrowseTarget(browseId: id, params: params).moodChipID, title: .verbatim(title))
    }
}

extension QTShelfItem {
    /// The track of a track or video item.
    public var track: QTTrack? {
        switch self {
        case .track(let t), .video(let t): t
        default: nil
        }
    }
}

/// A browse destination: `browseId` + optional `params` (mood pages, filtered home).
public struct QTBrowseTarget: Sendable, Hashable {
    public var browseId: String
    public var params: String?

    public init(browseId: String, params: String? = nil) {
        self.browseId = browseId
        self.params = params
    }

    /// `QTMoodChip.id` encoding: `browseId` or `browseId/params` (browse ids never contain "/").
    public var moodChipID: String {
        params.map { "\(browseId)/\($0)" } ?? browseId
    }

    public init(moodChipID: String) {
        if let slash = moodChipID.firstIndex(of: "/") {
            browseId = String(moodChipID[..<slash])
            params = String(moodChipID[moodChipID.index(after: slash)...])
        } else {
            browseId = moodChipID
            params = nil
        }
    }
}
