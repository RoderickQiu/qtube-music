import Foundation
import QTCore
import Testing
@testable import QTUI

/// R6 window-data: Quick picks columns, the Liked count, the docked panel's width.
@Suite @MainActor struct QTWindowDataTests {
    /// A row narrower than ~260 pt (art + title + heart) truncates nearly every title, so the column count follows
    /// the width — the same in light and dark, demo and live.
    @Test func quickPicksColumnsKeepTitlesReadable() {
        let gutters = QTTheme.Spacing.gutter * 2
        // The RC window with the panel open (content ≈ 660–720 pt): two columns, not three squeezed ones.
        #expect(QTQuickPicks.columnCount(forWidth: 723, tracks: 20, maxColumns: 3) == 2)
        #expect(QTQuickPicks.columnCount(forWidth: 659, tracks: 20, maxColumns: 3) == 2)
        // Panel hidden in the same window: three.
        #expect(QTQuickPicks.columnCount(forWidth: 1043, tracks: 20, maxColumns: 3) == 3)
        // Narrow: one; never more columns than songs; unmeasured: the wanted count.
        #expect(QTQuickPicks.columnCount(forWidth: 400, tracks: 20, maxColumns: 3) == 1)
        #expect(QTQuickPicks.columnCount(forWidth: 1400, tracks: 1, maxColumns: 3) == 1)
        #expect(QTQuickPicks.columnCount(forWidth: 0, tracks: 20, maxColumns: 3) == 3)
        // Every column gets at least the minimum row width.
        for width in stride(from: CGFloat(300), through: 1600, by: 37) {
            let n = QTQuickPicks.columnCount(forWidth: width, tracks: 20, maxColumns: 3)
            let row = (width - gutters - CGFloat(n - 1) * 20) / CGFloat(n)
            #expect(n == 1 || row >= QTQuickPicks.minRowWidth, "width \(width): \(n) columns of \(row) pt")
        }
        // A chart rank needs room of its own.
        #expect(QTQuickPicks.columnCount(forWidth: 970, tracks: 20, maxColumns: 3, ranked: true)
                <= QTQuickPicks.columnCount(forWidth: 970, tracks: 20, maxColumns: 3))
    }

    /// Liked Songs shows max(loaded rows, YouTube Music's count); minutes only once every song is here.
    @Test func likedCountMatchesYouTubeMusic() {
        let tracks = (0..<3).map { QTTrack(videoId: "v\($0)", title: "T\($0)", artists: [], duration: 200) }
        let liked = QTTrackCollection(id: "liked", kind: .liked, title: "Liked Songs", tracks: tracks, playlistID: "LM")
        let all = QTLibraryHeader.countLine(collection: liked, rows: tracks, filter: "")
        #expect(all == QTFormat.songCountAndMinutes(count: 3, seconds: 600))
        #expect(QTLibraryHeader.countLine(collection: liked, rows: tracks, filter: "", reportedCount: 2) == all)
        // Still streaming in: the count only. Done (unavailable rows left out): YouTube Music's count, the minutes here.
        let loading = QTLibraryHeader.countLine(collection: liked, rows: tracks, filter: "", reportedCount: 1234, isLoadingMore: true)
        #expect(loading == QTLoc.tr("%lld songs", table: .main, 1234))
        #expect(QTLibraryHeader.countLine(collection: liked, rows: tracks, filter: "", reportedCount: 5)
                == QTFormat.songCountAndMinutes(count: 5, seconds: 600))
        #expect(QTLibraryHeader.countLine(collection: liked, rows: [tracks[0]], filter: "t0", reportedCount: 1234)
                == QTLoc.tr("%lld of %lld songs", table: .main, 1, 1234))
        // The demo library has no YouTube Music count.
        #expect(QTLibraryHeader.reportedCount(for: liked) == nil)
    }

    @Test func panelWidthIsTheDesignWidthUntilTheUserDragsIt() {
        #expect(QTInspectorWidthKeeper.clamped(0) == QTTheme.Metrics.panelWidth)
        #expect(QTInspectorWidthKeeper.clamped(400) == 400)
        #expect(QTInspectorWidthKeeper.clamped(100) == QTTheme.Metrics.panelMinWidth)
        #expect(QTInspectorWidthKeeper.clamped(2000) == QTTheme.Metrics.panelMaxWidth)
        // Above the split view's holding priority for the inspector (261), never required.
        #expect(QTInspectorWidthKeeper.priority.rawValue > 261 && QTInspectorWidthKeeper.priority < .defaultHigh)
    }
}
