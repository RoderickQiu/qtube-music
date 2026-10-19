import Foundation
import QTCore
import QTInnerTube

// Owner: builder "window" (on data-live's store). The browse pages' view of the user's YouTube Music library:
// every request goes through `QTLiveCatalogStore`, which owns the client, resolves album/artist names to ids,
// remembers the tracks it sees (lyrics, playback) and caches each page with its phase.

@MainActor
final class QTLiveBrowseService: QTBrowseService {
    static let shared = QTLiveBrowseService()

    private var store: QTLiveCatalogStore { .shared }

    func cached(_ request: QTBrowseRequest) -> QTBrowseResponse? {
        guard phase(request) == .loaded else { return nil }
        switch request {
        case .explore:
            return store.explore.map { .explore(content($0)) }
        case .exploreSection(let s):
            return liveSection(s).map { .shelves(store.exploreSections[$0] ?? []) }
        case .moods:
            return .moods(store.moodsPage ?? QTMoodsPage(groups: []))
        case .mood(let chip):
            return .shelves(store.moodFeeds[Self.moodKey(chip)]?.shelves ?? [])
        case .search(let q):
            return store.searchResults[q].map { .search($0) }
        case .album(let k):
            return store.albumPages[k].map { .album($0) }
        case .artist(let k):
            return store.artistPages[k].map { .artist($0) }
        }
    }

    func load(_ request: QTBrowseRequest, force: Bool) async throws -> QTBrowseResponse? {
        switch request {
        case .explore: await store.loadExplore(force: force)
        case .exploreSection(let s):
            if let ls = liveSection(s) { await store.loadExploreSection(ls, force: force) } else { await store.loadExplore(force: force) }
        case .moods: await store.loadExploreSection(.moods, force: force)
        case .mood(let chip): await store.loadMoodPage(chip)
        case .search(let q): await store.search(q, force: force)
        case .album(let k): await store.loadAlbum(k, force: force)
        case .artist(let k): await store.loadArtist(k, force: force)
        }
        if case .failed(let f) = phase(request) { throw QTBrowseFailure(f) }
        return cached(request)
    }

    // MARK: Mapping

    private func phase(_ request: QTBrowseRequest) -> QTLivePhase {
        switch request {
        case .explore: store.explorePhase
        case .exploreSection(let s): liveSection(s).map { store.exploreSectionPhases[$0] ?? .idle } ?? store.explorePhase
        case .moods: store.exploreSectionPhases[.moods] ?? .idle
        case .mood(let chip): store.moodPhases[Self.moodKey(chip)] ?? .idle
        case .search(let q): store.searchPhases[q] ?? .idle
        case .album(let k): store.albumPhases[k] ?? .idle
        case .artist(let k): store.artistPhases[k] ?? .idle
        }
    }

    private func liveSection(_ s: QTExploreSection) -> QTLiveExploreSection? {
        switch s {
        case .overview: nil
        case .newReleases: .newReleases
        case .charts: .charts
        case .moods: .moods
        }
    }

    /// The store's key for a mood page.
    static func moodKey(_ chip: QTMoodChip) -> String { "moodpage:\(chip.id)" }

    /// Overview shelves + the server-localized names of Explore's own destinations.
    private func content(_ page: QTExplorePage) -> QTExploreContent {
        var titles: [QTExploreSection: String] = [:]
        for d in page.destinations {
            switch QTBrowseTarget(moodChipID: d.id).browseId {
            case "FEmusic_new_releases": titles[.newReleases] = d.title.resolved
            case "FEmusic_charts": titles[.charts] = d.title.resolved
            case "FEmusic_moods_and_genres": titles[.moods] = d.title.resolved
            default: break
            }
        }
        return QTExploreContent(shelves: page.shelves, sectionTitles: titles)
    }
}
