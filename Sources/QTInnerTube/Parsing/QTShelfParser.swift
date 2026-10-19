import Foundation
import QTCore

/// Section lists, shelves and continuations — the scaffolding every browse/search response shares.
enum QTShelfParser {
    // MARK: Section lists

    /// Every section of a response's main section list(s), in order. Handles single- and two-column browse
    /// results (tab content + `secondaryContents`), search results and `sectionListContinuation`.
    static func sections(_ response: QTJSON) -> [QTJSON] {
        var out: [QTJSON] = []
        let contents = response["contents"]
        let single = contents["singleColumnBrowseResultsRenderer"]
        for tab in single["tabs"].array {
            out += tab[path: "tabRenderer", "content", "sectionListRenderer", "contents"].array
        }
        let two = contents["twoColumnBrowseResultsRenderer"]
        for tab in two["tabs"].array {
            out += tab[path: "tabRenderer", "content", "sectionListRenderer", "contents"].array
        }
        out += two[path: "secondaryContents", "sectionListRenderer", "contents"].array
        for tab in contents[path: "tabbedSearchResultsRenderer", "tabs"].array {
            out += tab[path: "tabRenderer", "content", "sectionListRenderer", "contents"].array
        }
        // Lyrics/related browse pages: a bare section list.
        out += contents[path: "sectionListRenderer", "contents"].array
        out += response[path: "continuationContents", "sectionListContinuation", "contents"].array
        return out
    }

    /// The main section list renderer (for its header chips and continuation).
    static func sectionList(_ response: QTJSON) -> QTJSON {
        if let cont = response["continuationContents"]["sectionListContinuation"].object { return .object(cont) }
        let contents = response["contents"]
        for path in [["singleColumnBrowseResultsRenderer"], ["twoColumnBrowseResultsRenderer"], ["tabbedSearchResultsRenderer"]] {
            for tab in contents[path[0]]["tabs"].array {
                let sl = tab[path: "tabRenderer", "content", "sectionListRenderer"]
                if !sl.isNull { return sl }
            }
        }
        return .null
    }

    // MARK: Continuations

    /// Continuation token from a renderer's `continuations` array (`nextContinuationData`,
    /// `nextRadioContinuationData`, `reloadContinuationData`).
    static func continuation(_ renderer: QTJSON) -> QTContinuation? {
        for c in renderer["continuations"].array {
            for key in ["nextContinuationData", "nextRadioContinuationData", "reloadContinuationData"] {
                if let t = c[key]["continuation"].string { return QTContinuation(t) }
            }
        }
        return nil
    }

    /// Continuation token from a trailing `continuationItemRenderer` in an item list.
    static func continuationItem(_ items: [QTJSON]) -> QTContinuation? {
        for item in items.reversed() {
            let c = item["continuationItemRenderer"]
            if c.isNull { continue }
            if let t = c.first("token")?.string ?? c.first("continuation")?.string { return QTContinuation(t) }
        }
        return nil
    }

    // MARK: Shelves

    /// A carousel / list / grid section → shelf. nil when it's empty after the music-only filter or when most of
    /// it was non-music (a podcast shelf with a stray song is still a podcast shelf).
    static func shelf(_ section: QTJSON, index: Int, context: QTItemContext = .plain) -> QTShelf? {
        guard let key = section.rendererKey else { return nil }
        let r = section[key]
        let title: String?
        let raw: [QTJSON]
        let titleNav: QTNavigation?
        switch key {
        case "musicCarouselShelfRenderer", "musicImmersiveCarouselShelfRenderer":
            let header = r["header"].rendererValue
            title = header["title"].text
            titleNav = header["title"].runs.first?.navigation ?? header["moreContentButton"].first("navigationEndpoint")
                .flatMap(QTNavigation.init)
            raw = r["contents"].array
        case "musicShelfRenderer", "musicPlaylistShelfRenderer":
            title = r["title"].text
            titleNav = r["title"].runs.first?.navigation ?? r.navigation("bottomEndpoint")
            raw = r["contents"].array
        case "gridRenderer":
            title = r["header"].rendererValue["title"].text
            titleNav = nil
            raw = r["items"].array
        default:
            return nil
        }
        let parsed = QTItemParser.items(raw, context: context)
        guard !parsed.items.isEmpty, parsed.nonMusic <= parsed.items.count else { return nil }
        let style = style(for: parsed.items, raw: raw)
        let id: String = {
            if let b = titleNav?.browseId { return "shelf:\(b)" }
            return "shelf:\(index):\(title ?? key)"
        }()
        // One card per release (YouTube Music lists explicit/clean and re-titled editions side by side).
        let items = QTResultTidying.dedupingReleases(parsed.items, playlistIDs: albumPlaylistIDs(raw))
        return QTShelf(id: id, title: .verbatim(title ?? ""), style: style, items: items)
    }

    /// Album browse id → its playlist id (`OLAK5uy_…`, from the card's play overlay), for release de-duplication.
    static func albumPlaylistIDs(_ raw: [QTJSON]) -> [String: String] {
        var out: [String: String] = [:]
        for item in raw {
            let r = item["musicTwoRowItemRenderer"]
            guard !r.isNull, let browseId = r.navigation("navigationEndpoint")?.browseId, browseId.hasPrefix("MPRE"),
                  let pl = r["thumbnailOverlay"].first("playlistId")?.string else { continue }
            out[browseId] = pl
        }
        return out
    }

    static func style(for items: [QTShelfItem], raw: [QTJSON]) -> QTShelfStyle {
        let videos = items.filter { if case .video = $0 { true } else { false } }.count
        let aspect169 = raw.contains {
            $0["musicTwoRowItemRenderer"]["aspectRatio"].string == "MUSIC_TWO_ROW_ITEM_THUMBNAIL_ASPECT_RATIO_RECTANGLE_16_9"
        }
        if aspect169 || (videos * 2 > items.count && raw.first?.rendererKey == "musicTwoRowItemRenderer") {
            return .videos
        }
        if raw.first?.rendererKey == "musicResponsiveListItemRenderer", items.allSatisfy({ $0.track != nil }) {
            return .quickPicks
        }
        return .cards
    }

    /// All shelves of a response, music only.
    static func shelves(_ response: QTJSON, context: QTItemContext = .plain) -> [QTShelf] {
        sections(response).enumerated().compactMap { shelf($1, index: $0, context: context) }
    }
}
