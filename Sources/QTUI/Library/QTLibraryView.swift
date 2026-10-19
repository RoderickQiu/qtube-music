import QTCore
import SwiftUI

// Owner: builder "window". Stub: playlist header + native Table. To build: sticky compact header, ⌘F filter,
// A–Z strip, Finder-style selection (click selects, double-click/↩ plays), NSMenu context menu, drag to playlists.
// (Big libraries: consider NSTableView via NSViewRepresentable.)

public struct QTLibraryView: View {
    private let playlist: QTPlaylist
    @Environment(QTAppModel.self) private var model
    @Environment(QTPlayerModel.self) private var player

    public init(playlist: QTPlaylist) {
        self.playlist = playlist
    }

    public var body: some View {
        @Bindable var model = model
        let tracks = playlist.tracks ?? []
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 28) {
                QTArtworkView(playlist.artwork, cornerRadius: QTTheme.Radius.artworkLarge,
                              placeholder: playlist.kind == .liked ? .heartFill : .playlist)
                    .frame(width: QTTheme.Metrics.playlistTile, height: QTTheme.Metrics.playlistTile)
                VStack(alignment: .leading, spacing: 6) {
                    Text(QTLoc.tr("Playlist")).font(QTTheme.Typography.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(playlist.title.resolved).font(QTTheme.Typography.pageTitle)
                    Text(QTFormat.songCountAndMinutes(count: playlist.trackCount, seconds: playlist.totalDuration))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button {
                            Task { await player.play(tracks.filter { $0.availability.isPlayable }) }
                        } label: {
                            Label(QTLoc.tr("Play"), systemImage: QTIcon.play.systemName)
                        }
                        .buttonStyle(.borderedProminent)
                        Button {
                            player.isShuffleOn = true
                            let playable = tracks.filter { $0.availability.isPlayable }.shuffled()
                            Task { await player.play(playable) }
                        } label: {
                            Label(QTLoc.tr("Shuffle"), systemImage: QTIcon.shuffle.systemName)
                        }
                        .buttonStyle(.bordered)
                    }
                    .controlSize(.large)
                    .padding(.top, 12)
                }
                Spacer()
            }
            .padding(.horizontal, QTTheme.Spacing.gutter)
            .padding(.top, 36)
            .padding(.bottom, 28)

            Table(tracks, selection: $model.selectedTrackIDs) {
                TableColumn(QTLoc.tr("Title")) { t in
                    HStack(spacing: 14) {
                        QTArtworkView(track: t, cornerRadius: 4)
                            .frame(width: QTTheme.Metrics.rowArtwork, height: QTTheme.Metrics.rowArtwork)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.title).font(QTTheme.Typography.rowTitle).lineLimit(1)
                            Text(t.artistLine).font(QTTheme.Typography.secondary).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .opacity(t.availability.isPlayable ? 1 : 0.42)
                }
                .width(min: 220, ideal: 360)
                TableColumn(QTLoc.tr("Album")) { t in
                    Text(t.album?.title ?? "").foregroundStyle(.secondary).lineLimit(1)
                }
                .width(min: 140, ideal: 240)
                TableColumn(QTLoc.tr("Time")) { t in
                    Text(QTFormat.duration(t.duration)).monospacedDigit().foregroundStyle(.secondary)
                }
                .width(56)
                .alignment(.trailing)
            }
            .tableStyle(.inset)
            .contextMenu(forSelectionType: QTTrack.ID.self) { _ in
                Button(QTLoc.tr("Play")) {}
                Button(QTLoc.tr("Play Next")) {}
                Button(QTLoc.tr("Add to Queue")) {}
            } primaryAction: { ids in
                guard let id = ids.first, let i = tracks.firstIndex(where: { $0.id == id }) else { return }
                Task { await player.play(tracks, startingAt: i) }
            }
        }
        .accessibilityIdentifier("qt.library")
    }
}
