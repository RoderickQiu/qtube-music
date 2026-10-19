import QTCore
import SwiftUI

// Owner: builder "window". Library › Albums and Artists, derived from the library's songs until the data layer
// (M3) brings real album/artist pages. Cards open the album/artist track list.

struct QTLibraryAlbum: Identifiable, Hashable {
    var id: String { title }
    let title: String
    let artist: String
    let artwork: [QTArtworkImage]
    let sortKey: String
}

struct QTLibraryArtist: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let artwork: [QTArtworkImage]
    let songCount: Int
    let sortKey: String
}

enum QTLibraryIndex {
    static func albums(_ tracks: [QTTrack]) -> [QTLibraryAlbum] {
        var seen = Set<String>()
        return tracks.compactMap { t -> QTLibraryAlbum? in
            guard let a = t.album?.title, seen.insert(a).inserted else { return nil }
            return QTLibraryAlbum(title: a, artist: t.artistLine, artwork: t.artwork, sortKey: QTTextFolding.sortKey(a))
        }.sorted { $0.sortKey.compare($1.sortKey, options: .numeric) == .orderedAscending }
    }

    static func artists(_ tracks: [QTTrack]) -> [QTLibraryArtist] {
        var order: [String] = []
        var info: [String: (art: [QTArtworkImage], count: Int)] = [:]
        for t in tracks {
            for a in t.artists {
                if info[a.name] == nil { order.append(a.name); info[a.name] = (t.artwork, 0) }
                info[a.name]?.count += 1
            }
        }
        return order.map { QTLibraryArtist(name: $0, artwork: info[$0]?.art ?? [], songCount: info[$0]?.count ?? 0,
                                           sortKey: QTTextFolding.sortKey($0)) }
            .sorted { $0.sortKey.compare($1.sortKey, options: .numeric) == .orderedAscending }
    }
}

struct QTLibraryGridPage<Item: Identifiable, Card: View>: View {
    let title: String
    let items: [Item]
    let identifier: String
    @ViewBuilder let card: (Item) -> Card

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(verbatim: title)
                    .font(QTTheme.Typography.pageTitle)
                    .accessibilityAddTraits(.isHeader)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: QTTheme.Metrics.card, maximum: QTTheme.Metrics.card + 24),
                                             spacing: QTTheme.Spacing.shelfGap, alignment: .top)],
                          alignment: .leading, spacing: 28) {
                    ForEach(items) { card($0) }
                }
            }
            .padding(.horizontal, QTTheme.Spacing.gutter)
            .padding(.top, 40)
            .padding(.bottom, 48)
        }
        .accessibilityIdentifier(identifier)
    }
}

struct QTAlbumsPage: View {
    @Environment(QTAppModel.self) private var model

    var body: some View {
        QTLibraryGridPage(title: QTLoc.tr("Albums"), items: QTLibraryIndex.albums(model.catalog.tracks), identifier: "qt.library.albums") { album in
            QTGridCard(title: album.title, subtitle: album.artist, circular: false, placeholder: .album) {
                QTArtworkView(album.artwork, placeholder: .album)
            } action: {
                QTNavigator.shared.go(.album(album.title))
            }
        }
    }
}

struct QTArtistsPage: View {
    @Environment(QTAppModel.self) private var model

    var body: some View {
        QTLibraryGridPage(title: QTLoc.tr("Artists"), items: QTLibraryIndex.artists(model.catalog.tracks), identifier: "qt.library.artists") { artist in
            QTGridCard(title: artist.name, subtitle: QTLoc.tr("%lld songs", table: .main, artist.songCount), circular: true, placeholder: .mic) {
                QTArtworkView(artist.artwork, cornerRadius: QTTheme.Metrics.card / 2, placeholder: .mic)
            } action: {
                QTNavigator.shared.go(.artist(artist.name))
            }
        }
    }
}

/// Grid card with hover zoom + soft shadow (same feel as Home cards).
struct QTGridCard<Art: View>: View {
    let title: String
    let subtitle: String
    let circular: Bool
    let placeholder: QTIcon
    @ViewBuilder let art: () -> Art
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(alignment: circular ? .center : .leading, spacing: 4) {
                art()
                    .aspectRatio(1, contentMode: .fit)
                    .scaleEffect(isHovered && !reduceMotion ? 1.04 : 1)
                    .clipShape(circular ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: QTTheme.Radius.artwork, style: .continuous)))
                    .shadow(color: .black.opacity(isHovered ? 0.28 : 0.18), radius: isHovered ? 12 : 8, y: 4)
                    .animation(QTTheme.Motion.animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.4), reduceMotion: reduceMotion), value: isHovered)
                    .padding(.bottom, 6)
                Text(verbatim: title).font(QTTheme.Typography.rowTitle).lineLimit(1)
                Text(verbatim: subtitle).font(QTTheme.Typography.secondary).foregroundStyle(.secondary).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(title)
    }
}
