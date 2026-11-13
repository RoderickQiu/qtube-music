import QTCore
import SwiftUI

/// "Suggestions" after the last row of one of the account's own playlists (issue #6): songs YouTube Music picked
/// from what the playlist holds. Each row plays on a double-click and has a button that adds it to this playlist
/// (the row then leaves the list); Refresh asks for another set. Hosted as the track table's footer
/// (`QTTrackTable.footer`), so it scrolls with the rows and is exactly as wide as they are.
struct QTPlaylistSuggestionsSection: View {
    let playlist: QTPlaylist
    let suggestions: QTLivePlaylistSuggestions
    @Environment(QTAppModel.self) private var model
    @State private var width: CGFloat = 0

    static let rowHeight = QTTheme.Metrics.tableRowHeight
    private static let topSpace: CGFloat = 36
    private static let headingHeight: CGFloat = 50
    private static let refreshHeight: CGFloat = 46

    /// The footer's height for what it shows (AppKit lays the host out; SwiftUI doesn't size it).
    static func height(for suggestions: QTLivePlaylistSuggestions) -> CGFloat {
        topSpace + headingHeight + CGFloat(suggestions.tracks.count) * rowHeight + (suggestions.canRefresh ? refreshHeight : 0)
    }

    var body: some View {
        let store = QTLiveCatalogStore.shared
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(QTLoc.tr("Suggestions", table: .main))
                    .font(QTTheme.Typography.shelfTitle)
                    .accessibilityAddTraits(.isHeader)
                Text(QTLoc.tr("Based on the songs in this playlist", table: .main))
                    .font(QTTheme.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.leading, QTPlaylistSuggestionRow.inset(width: width))
            .frame(height: Self.headingHeight, alignment: .top)
            ForEach(suggestions.tracks, id: \.videoId) { track in
                QTPlaylistSuggestionRow(track: track, tracks: suggestions.tracks, playlist: playlist, width: width)
                    .frame(height: Self.rowHeight)
            }
            if suggestions.canRefresh {
                HStack(spacing: QTTheme.Spacing.s) {
                    Button(QTLoc.tr("Refresh", table: .main)) {
                        Task { await store.refreshSuggestions(for: playlist.id) }
                    }
                    .disabled(suggestions.isRefreshing)
                    .help(QTLoc.tr("Show other suggestions", table: .main))
                    .accessibilityIdentifier("qt.library.suggestions.refresh")
                    if suggestions.isRefreshing { ProgressView().controlSize(.small) }
                }
                .padding(.leading, QTPlaylistSuggestionRow.inset(width: width))
                .frame(height: Self.refreshHeight, alignment: .bottom)
            }
        }
        .padding(.top, Self.topSpace)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("qt.library.suggestions")
    }
}

struct QTPlaylistSuggestionRow: View {
    let track: QTTrack
    let tracks: [QTTrack]
    let playlist: QTPlaylist
    /// The section's width — the track table's, so the row's columns can sit under the table's.
    let width: CGFloat
    @Environment(QTPlayerModel.self) private var player
    @State private var isHovered = false

    /// The table's fixed columns (`QTTrackTableCoordinator`): #, the heart and the time. A suggestion's artwork,
    /// album, add button and length sit under the table's artwork, album, heart and time, so the two lists read as
    /// one; the title and album share the rest as the table's columns do by default (380 : 250).
    /// In a very narrow list (a small window with the panel open) the # indent and the length give way to the title.
    static func inset(width: CGFloat) -> CGFloat { width >= 420 ? 40 : 0 }
    private static let buttonColumn: CGFloat = 44
    private static let timeColumn: CGFloat = 72
    private var showsTime: Bool { width >= 420 }
    private var showsAlbum: Bool { width >= 560 }
    private var albumWidth: CGFloat {
        showsAlbum ? ((width - Self.inset(width: width) - Self.buttonColumn - Self.timeColumn) * 250 / 630).rounded() : 0
    }

    var body: some View {
        let isCurrent = player.nowPlaying?.videoId == track.videoId
        let addTitle = QTLoc.tr("Add to %@", table: .main, playlist.title.resolved)
        HStack(spacing: 0) {
            Button(action: play) {
                QTArtworkView(track: track, cornerRadius: QTTheme.Radius.control)
                    .frame(width: QTTheme.Metrics.rowArtwork, height: QTTheme.Metrics.rowArtwork)
                    .overlay {
                        RoundedRectangle(cornerRadius: QTTheme.Radius.control, style: .continuous)
                            .fill(.black.opacity(0.4))
                            .overlay {
                                if isHovered {
                                    (isCurrent && player.isPlaybackRequested ? QTIcon.pause : QTIcon.play).image.foregroundStyle(.white)
                                } else if isCurrent {
                                    QTNowPlayingGlyph(isPlaying: player.isPlaying, pointSize: 13, weight: .semibold, tint: .white)
                                }
                            }
                            .opacity(isHovered || isCurrent ? 1 : 0)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(QTLoc.tr("Play %@", track.title))
            .padding(.leading, Self.inset(width: width))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: track.title)
                    .font(QTTheme.Typography.rowTitle)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Text(verbatim: track.artistLine)
                    .font(QTTheme.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            if showsAlbum {
                Text(verbatim: track.album?.title ?? "")
                    .font(QTTheme.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.trailing, 8)
                    .frame(width: albumWidth, alignment: .leading)
            }
            Button(action: add) {
                Label(addTitle, systemImage: "plus.circle")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 16))
            }
            .buttonStyle(.borderless)
            .frame(width: Self.buttonColumn)
            .help(addTitle)
            .accessibilityIdentifier("qt.library.suggestions.add.\(track.videoId)")
            if showsTime {
                Text(verbatim: track.duration > 0 ? QTFormat.duration(track.duration) : "")
                    .font(QTTheme.Typography.secondary)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 8)
                    .frame(width: Self.timeColumn, alignment: .trailing)
            }
        }
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: QTTheme.Radius.artwork, style: .continuous)
            .fill(isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2, perform: play)
        .qtTrackContextMenu(track)
        .draggable(QTTrackActions.dragString(for: track))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("qt.library.suggestion.\(track.videoId)")
    }

    private func play() {
        if player.nowPlaying?.videoId == track.videoId { player.togglePlayPause(); return }
        QTTrackActions.play(tracks, at: tracks.firstIndex(of: track) ?? 0,
                            source: QTQueueSource(kind: .playlist, title: .verbatim(QTLoc.tr("Suggestions", table: .main))))
    }

    private func add() {
        QTTrackActions.add([track], to: playlist)
        QTLiveCatalogStore.shared.suggestionWasAdded(to: playlist)
    }
}
