import QTCore
import SwiftUI

// Owner: builder "window". Stub: greeting + mood chips + shelves from the catalog's home feed.
// (ADR-0038 in Kaset: AppKit beats SwiftUI for big scrolling shelves — consider NSCollectionView later.)

public struct QTHomeView: View {
    @Environment(QTAppModel.self) private var model
    @Environment(QTPlayerModel.self) private var player

    public init() {}

    public var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: QTTheme.Spacing.shelfSpacing) {
                VStack(alignment: .leading, spacing: 18) {
                    Text(Self.greeting(at: .now))
                        .font(QTTheme.Typography.pageTitle)
                    HStack(spacing: QTTheme.Spacing.xs) {
                        ForEach(model.catalog.home.moods) { mood in
                            Button(mood.title.resolved) {}
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                                .controlSize(.large)
                        }
                    }
                }
                .padding(.top, 40)
                .padding(.horizontal, QTTheme.Spacing.gutter)

                ForEach(model.catalog.home.shelves) { shelf in
                    VStack(alignment: .leading, spacing: 14) {
                        Text(shelf.title.resolved)
                            .font(QTTheme.Typography.shelfTitle)
                            .padding(.horizontal, QTTheme.Spacing.gutter)
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: QTTheme.Spacing.shelfGap) {
                                ForEach(shelf.items) { item in card(item, style: shelf.style) }
                            }
                            .padding(.horizontal, QTTheme.Spacing.gutter)
                        }
                        .scrollIndicators(.never)
                    }
                }
            }
            .padding(.bottom, 48)
        }
        .accessibilityIdentifier("qt.home")
    }

    @ViewBuilder
    private func card(_ item: QTShelfItem, style: QTShelfStyle) -> some View {
        switch item {
        case .track(let t), .video(let t):
            let isVideo = { if case .video = item { return true } else { return false } }()
            let w = isVideo ? QTTheme.Metrics.videoCardWidth : QTTheme.Metrics.card
            let h = isVideo ? QTTheme.Metrics.videoCardHeight : QTTheme.Metrics.card
            VStack(alignment: .leading, spacing: 4) {
                QTArtworkView(track: t, video: isVideo)
                    .frame(width: w, height: h)
                    .padding(.bottom, 6)
                Text(t.title).font(QTTheme.Typography.rowTitle).lineLimit(1)
                Text(t.artistLine).font(QTTheme.Typography.secondary).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: w, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                let tracks = shelfTracks()
                Task { await player.play(tracks, startingAt: tracks.firstIndex(of: t) ?? 0, mode: isVideo ? .video : .song) }
            }
        case .playlist(let p):
            VStack(alignment: .leading, spacing: 4) {
                QTArtworkView(p.artwork, placeholder: p.kind == .liked ? .heartFill : .playlist)
                    .frame(width: QTTheme.Metrics.card, height: QTTheme.Metrics.card)
                    .padding(.bottom, 6)
                Text(p.title.resolved).font(QTTheme.Typography.rowTitle).lineLimit(1)
                Text(p.kind == .liked ? QTFormat.songCountAndMinutes(count: p.trackCount, seconds: p.totalDuration) : QTLoc.tr("Playlist"))
                    .font(QTTheme.Typography.secondary).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: QTTheme.Metrics.card, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { model.sidebarSelection = p.kind == .liked ? .liked : .playlist(p.id) }
        case .album, .artist:
            EmptyView()
        }
    }

    private func shelfTracks() -> [QTTrack] {
        (model.catalog.liked.tracks ?? []).filter { $0.availability.isPlayable }
    }

    /// Prototype greeting buckets: <5 night, <12 morning, <18 afternoon, else evening.
    static func greeting(at date: Date, calendar: Calendar = .current) -> String {
        let h = calendar.component(.hour, from: date)
        return QTLoc.tr(h < 5 ? "Good night" : h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening")
    }
}
