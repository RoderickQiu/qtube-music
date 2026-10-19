import Foundation
import QTCore
import Testing
@testable import QTUI

/// R7 home-shelves: song shelves page sideways in up to four rows; See All opens the whole list.
@Suite @MainActor struct QTSongShelfTests {
    @Test func songShelfPagesInFourRows() {
        // A 20-song shelf in the panel-open window (two columns a page): four rows, five columns, paged.
        let wide = QTSongShelfLayout(width: 723, tracks: 20, ranked: false)
        #expect(wide.perPage == 2)
        #expect(wide.rows == 4)
        #expect(wide.columns == 5)
        #expect(wide.pages)
        // Columns fill the width between the gutters exactly (the next page's first column peeks in the gutter).
        let inner = 723 - QTTheme.Spacing.gutter * 2
        #expect(abs(wide.columnWidth * 2 + QTSongShelfLayout.columnSpacing - inner) < 0.001)
        // Columns run top to bottom, YouTube Music's order; the last one may be short.
        #expect(wide.range(ofColumn: 0, tracks: 20) == 0..<4)
        #expect(wide.range(ofColumn: 4, tracks: 20) == 16..<20)
        let odd = QTSongShelfLayout(width: 723, tracks: 19, ranked: false)
        #expect(odd.range(ofColumn: 4, tracks: 19) == 16..<19)
        // A short shelf fits one page: fewer rows, no paging (and so no See All).
        let short = QTSongShelfLayout(width: 1043, tracks: 9, ranked: false)
        #expect(short.perPage == 3 && short.rows == 3 && short.columns == 3 && !short.pages)
        let tiny = QTSongShelfLayout(width: 1043, tracks: 2, ranked: false)
        #expect(tiny.rows == 1 && tiny.columns == 2 && !tiny.pages)
        // Narrow: one column a page.
        let narrow = QTSongShelfLayout(width: 400, tracks: 20, ranked: false)
        #expect(narrow.perPage == 1 && narrow.columns == 5 && narrow.pages)
        // Unmeasured: a sane width, never zero or negative.
        #expect(QTSongShelfLayout(width: 0, tracks: 20, ranked: false).columnWidth == QTQuickPicks.minRowWidth)
    }

    @Test func seeAllListsTheWholeShelf() {
        let tracks = (0..<6).map { QTTrack(videoId: "v\($0)", title: "T\($0)", artists: [], duration: 0) }
        let shelf = QTShelf(id: "trending", title: .verbatim("Trending songs for you"), style: .quickPicks,
                            items: tracks.prefix(4).map { .track($0) } + tracks.suffix(2).map { .video($0) })
        let collection = QTTrackCollection.shelf(shelf)
        #expect(collection.tracks.map(\.videoId) == tracks.map(\.videoId))
        #expect(collection.title == "Trending songs for you")
        // Filter, sort and scroll survive Back, like every track list.
        #expect(QTTrackCollection.listKey(for: .shelf(shelf)) == collection.id)
        #expect(QTDestination.shelf(shelf).stateKey == "shelf:trending")
        // Home shelves carry no durations: the count alone, not "6 songs · 0 min".
        #expect(QTLibraryHeader.countLine(collection: collection, rows: collection.tracks, filter: "")
                == QTLoc.tr("%lld songs", table: .main, 6))
    }
}
