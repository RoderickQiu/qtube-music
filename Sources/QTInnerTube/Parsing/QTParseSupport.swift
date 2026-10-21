import Foundation
import QTCore

// Parsing primitives shared by every InnerTube parser: text runs, navigation endpoints, thumbnails, durations,
// years and the music-only filter. Shapes verified against anonymous WEB_REMIX responses recorded 2026-10-18
// (Tests/QTInnerTubeTests/Fixtures). Classification is always by endpoint type / page type / video type, never
// by localized labels, so the same code works for `hl=en` and `hl=zh-CN`.
//
// Approach informed by Kaset (MIT, github.com/sozercan/kaset — Services/API/Parsers), re-implemented here.

/// YouTube Music page types carried in `browseEndpointContextMusicConfig.pageType`.
public enum QTPageType: String, Sendable, Hashable {
    case album = "MUSIC_PAGE_TYPE_ALBUM"
    case audiobook = "MUSIC_PAGE_TYPE_AUDIOBOOK"
    case artist = "MUSIC_PAGE_TYPE_ARTIST"
    case artistDiscography = "MUSIC_PAGE_TYPE_ARTIST_DISCOGRAPHY"
    case playlist = "MUSIC_PAGE_TYPE_PLAYLIST"
    case userChannel = "MUSIC_PAGE_TYPE_USER_CHANNEL"
    case libraryArtist = "MUSIC_PAGE_TYPE_LIBRARY_ARTIST"
    case podcastShow = "MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE"
    case nonMusicAudioTrack = "MUSIC_PAGE_TYPE_NON_MUSIC_AUDIO_TRACK_PAGE"
    case trackLyrics = "MUSIC_PAGE_TYPE_TRACK_LYRICS"
    case trackRelated = "MUSIC_PAGE_TYPE_TRACK_RELATED"
    case trackCredits = "MUSIC_PAGE_TYPE_TRACK_CREDITS"
}

/// A navigation endpoint, reduced to what the app needs.
public enum QTNavigation: Sendable, Hashable {
    case watch(videoId: String, playlistId: String?, params: String?, musicVideoType: String?)
    case watchPlaylist(playlistId: String, params: String?)
    case browse(browseId: String, params: String?, pageType: String?)
    case search(query: String, params: String?)

    /// Parses the first recognised endpoint inside `json` (an object holding `watchEndpoint`, `browseEndpoint`…).
    init?(_ json: QTJSON) {
        let w = json["watchEndpoint"]
        if let videoId = w["videoId"].string {
            self = .watch(videoId: videoId, playlistId: w["playlistId"].string, params: w["params"].string,
                          musicVideoType: w[path: "watchEndpointMusicSupportedConfigs", "watchEndpointMusicConfig",
                                            "musicVideoType"].string)
            return
        }
        let wp = json["watchPlaylistEndpoint"]
        if let playlistId = wp["playlistId"].string {
            self = .watchPlaylist(playlistId: playlistId, params: wp["params"].string)
            return
        }
        let b = json["browseEndpoint"]
        if let browseId = b["browseId"].string {
            self = .browse(browseId: browseId, params: b["params"].string,
                           pageType: b[path: "browseEndpointContextSupportedConfigs", "browseEndpointContextMusicConfig",
                                       "pageType"].string)
            return
        }
        let s = json["searchEndpoint"]
        if let query = s["query"].string {
            self = .search(query: query, params: s["params"].string)
            return
        }
        return nil
    }

    var videoId: String? {
        if case .watch(let id, _, _, _) = self { return id }
        return nil
    }

    var browseId: String? {
        if case .browse(let id, _, _) = self { return id }
        return nil
    }

    /// The page type; an upload's album or artist (`FEmusic_library_privately_owned_…_detail…`) counts as an album or
    /// library artist whatever page type the link names, so upload rows link like any other.
    var pageType: QTPageType? {
        guard case .browse(let id, _, let p) = self else { return nil }
        if QTUploads.isAlbumID(id) { return .album }
        if QTUploads.isArtistID(id) { return .libraryArtist }
        return p.flatMap(QTPageType.init(rawValue:))
    }

    var musicVideoTypeRaw: String? {
        if case .watch(_, _, _, let t) = self { return t }
        return nil
    }
}

/// One text run.
struct QTRun: Sendable, Hashable {
    var text: String
    var navigation: QTNavigation?

    var isSeparator: Bool {
        text.trimmingCharacters(in: .whitespaces) == "•"
    }
}

extension QTJSON {
    /// Runs of a `{"runs": […]}` text object (also accepts `simpleText` and view-model `content`).
    var runs: [QTRun] {
        if let simple = self["simpleText"].string { return [QTRun(text: simple)] }
        if let content = self["content"].string { return [QTRun(text: content)] }
        return self["runs"].array.compactMap { run in
            guard let text = run["text"].string else { return nil }
            return QTRun(text: text, navigation: QTNavigation(run["navigationEndpoint"]))
        }
    }

    /// Concatenated text of a text object, trimmed; nil when empty.
    var text: String? {
        let s = runs.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// The first navigation endpoint stored under `key` (or self).
    func navigation(_ key: String? = nil) -> QTNavigation? {
        QTNavigation(key.map { self[$0] } ?? self)
    }
}

extension Array where Element == QTRun {
    /// Runs grouped between " • " separators, empty groups removed.
    var groups: [[QTRun]] {
        var out: [[QTRun]] = [[]]
        for run in self {
            if run.isSeparator {
                out.append([])
            } else {
                out[out.count - 1].append(run)
            }
        }
        return out.filter { !$0.isEmpty && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var text: String { map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Linked artists (artist pages, or uploader channels for user videos).
    var artistRefs: [QTArtistRef] {
        compactMap { run in
            guard let nav = run.navigation, case .browse(let id, _, _) = nav else { return nil }
            switch nav.pageType {
            case .artist, .userChannel, .libraryArtist:
                return QTArtistRef(id: id, name: run.text.trimmingCharacters(in: .whitespacesAndNewlines))
            default: return nil
            }
        }
    }

    var albumRef: QTAlbumRef? {
        for run in self {
            if let nav = run.navigation, nav.pageType == .album, let id = nav.browseId {
                return QTAlbumRef(id: id, title: run.text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return nil
    }
}

enum QTParse {
    // MARK: Durations and years

    /// "5:03" / "1:02:03" → seconds. Language-neutral (YouTube always uses colon clocks here).
    static func duration(_ text: String) -> TimeInterval? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard (2...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) }) else {
            return nil
        }
        return parts.reduce(0) { $0 * 60 + (TimeInterval(String($1)) ?? 0) }
    }

    /// "2004", "2004年" → 2004 (a group that is just a plausible year).
    static func year(_ text: String) -> Int? {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("年") { t.removeLast() }
        guard t.count == 4, t.allSatisfy(\.isASCIIDigit), let y = Int(t), (1900...2100).contains(y) else { return nil }
        return y
    }

    /// True for a group that is a statistic ("24M views", "播放次数：2亿", "12.9K subscribers"), a duration or a year.
    static func isStatistic(_ text: String) -> Bool {
        text.contains { $0.isNumber }
    }

    // MARK: Artwork

    /// Thumbnails of a `thumbnail` / `thumbnailRenderer` object, smallest → largest. Square YouTube Music art
    /// (googleusercontent `=wN-hN` URLs) is offered at 544 and 1200 px as well, so Stage and the inspector get a
    /// crisp image instead of an upscaled 120 px one.
    static func artwork(_ json: QTJSON) -> [QTArtworkImage] {
        let list = json.first("thumbnails")?.array ?? []
        var images: [QTArtworkImage] = list.compactMap { t in
            guard let s = t["url"].string, let url = URL(string: s.hasPrefix("//") ? "https:" + s : s) else {
                return nil
            }
            return QTArtworkImage(url: url, width: t["width"].int, height: t["height"].int)
        }
        images.sort { ($0.width ?? 0) < ($1.width ?? 0) }
        if let largest = images.last, let w = largest.width, let h = largest.height, w == h, w < 1200 {
            for size in [544, 1200] where size > w {
                if let url = resizedSquareURL(largest.url, size: size) {
                    images.append(QTArtworkImage(url: url, width: size, height: size))
                }
            }
        }
        return images
    }

    /// Rewrites the `=w120-h120-…` size suffix of a googleusercontent image URL.
    static func resizedSquareURL(_ url: URL, size: Int) -> URL? {
        guard let host = url.host, host.hasSuffix("googleusercontent.com") || host.hasSuffix("ggpht.com") else {
            return nil
        }
        let s = url.absoluteString
        guard let range = s.range(of: #"=w\d+-h\d+"#, options: .regularExpression) else { return nil }
        return URL(string: s.replacingCharacters(in: range, with: "=w\(size)-h\(size)"))
    }

    // MARK: Video types

    static func musicVideoType(_ raw: String?) -> QTMusicVideoType {
        guard let raw else { return .atv }
        if let known = QTMusicVideoType(rawValue: raw) { return known }
        switch raw {
        // Music a label uploads as a video on its channel (YouTube's "official source" program): a music video.
        case "MUSIC_VIDEO_TYPE_OFFICIAL_SOURCE_MUSIC": return .ugc
        // A song the user uploaded to their own library: audio.
        case privatelyOwnedType: return .atv
        default: return .other
        }
    }

    /// A song the user uploaded to their own library (`QTTrack.isPrivatelyOwned`).
    static let privatelyOwnedType = "MUSIC_VIDEO_TYPE_PRIVATELY_OWNED_TRACK"

    // MARK: Music-only filter

    /// True for podcasts, episodes, audiobooks, user profiles and other non-music destinations.
    /// The app is music only (HANDOFF §4), so these are dropped everywhere.
    static func isNonMusic(_ nav: QTNavigation?) -> Bool {
        guard let nav else { return false }
        switch nav {
        case .watch(_, _, _, let type):
            guard let type else { return false }
            return type.contains("PODCAST") || type.contains("EPISODE") || type.contains("AUDIOBOOK")
        case .browse(let id, _, let pageType):
            if QTUploads.isUploadID(id) { return false }
            if id.hasPrefix("MPSP") || id.hasPrefix("MPED") { return true }
            let lower = id.lowercased()
            if lower.contains("non_music") || lower.contains("podcast") || lower.contains("audiobook") { return true }
            switch pageType.flatMap(QTPageType.init(rawValue:)) {
            case .podcastShow, .nonMusicAudioTrack, .audiobook, .userChannel: return true
            default: return pageType?.contains("PODCAST") == true || pageType?.contains("EPISODE") == true
            }
        case .watchPlaylist, .search:
            return false
        }
    }

    /// Home mood chips: the "Podcasts" chip selects category 12 in its params (`SgQIDBAD`), in every language.
    static func isPodcastChip(params: String?, title: String) -> Bool {
        if let params, params.contains("SgQIDBAD") { return true }
        let t = title.lowercased()
        return t == "podcasts" || t == "podcast" || t == "播客"
    }

    // MARK: Ids

    /// Playlist browse id ("VL…") for a raw playlist id.
    static func playlistBrowseId(_ id: String) -> String {
        id.hasPrefix("VL") ? id : "VL" + id
    }

    /// Raw playlist id (what `next`/`watchPlaylist` take) for a browse id.
    static func rawPlaylistId(_ id: String) -> String {
        id.hasPrefix("VL") ? String(id.dropFirst(2)) : id
    }

    /// Mixes and radios (auto-generated, not user playlists). `RDCLAK` ids are YouTube Music's curated playlists.
    static func playlistKind(_ id: String) -> QTPlaylistKind {
        let raw = rawPlaylistId(id)
        if raw == "LM" { return .liked }
        if raw.hasPrefix("RD"), !raw.hasPrefix("RDCLAK") { return .mix }
        return .user
    }

    /// Album kind from the localized label at the start of an album subtitle ("Single", "单曲", "EP"…).
    static func albumKind(label: String) -> QTAlbumKind? {
        let l = label.trimmingCharacters(in: .whitespaces).lowercased()
        if l == "ep" || l.contains("迷你专辑") || l.contains("迷你專輯") { return .ep }
        if ["single", "单曲", "單曲", "đĩa đơn", "シングル", "싱글"].contains(l) { return .single }
        if ["album", "专辑", "專輯", "アルバム", "앨범"].contains(l) { return .album }
        return nil
    }

    /// The video id a row's "Add to queue" menu item names (`queueAddEndpoint.queueTarget.videoId`). Upload rows link
    /// nothing else to play (ytmusicapi `parse_uploaded_items`).
    static func queueAddVideoId(menu: QTJSON) -> String? {
        menu.all("queueAddEndpoint").lazy.compactMap { $0[path: "queueTarget", "videoId"].string }
            .first { !$0.isEmpty }
    }

    /// The row's menu offers to delete it from the account's uploads (`musicDeletePrivatelyOwnedEntityCommand`).
    static func hasDeleteUploadCommand(menu: QTJSON) -> Bool {
        menu.first("musicDeletePrivatelyOwnedEntityCommand") != nil
    }

    /// The audio-track video id from a row's "View song credits" menu entry (`MPTC<videoId>`). On official music
    /// video rows this is the Song counterpart; on audio rows it repeats the row's own id.
    /// Technique from Kaset (MIT) `ParsingHelpers+TrackCredits.swift`.
    static func creditsVideoId(menu: QTJSON) -> String? {
        for item in menu[path: "menuRenderer", "items"].array {
            guard let nav = item["menuNavigationItemRenderer"].navigation("navigationEndpoint"),
                  nav.pageType == .trackCredits, let id = nav.browseId, id.hasPrefix("MPTC") else { continue }
            let videoId = String(id.dropFirst(4))
            return videoId.isEmpty ? nil : videoId
        }
        return nil
    }
}

extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
