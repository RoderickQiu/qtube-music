import QTCore
import SwiftUI

// Owner: builder "data-live". Album and artist cards for live shelves (Home, Explore, search, artist pages), in the
// same family as QTHomeCard: artwork with hover zoom inside its clip, soft shadow, title + one quiet subtitle.
// Hovering prefetches the page; the play badge plays the album without opening it.

struct QTLiveAlbumCard: View {
    let album: QTAlbum
    @Environment(QTAppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var showsArtist = true

    var body: some View {
        // Not a Button: the play badge is its own button on top of the card.
        VStack(alignment: .leading, spacing: 4) {
            QTLiveCardArtwork(isHovered: isHovered, circular: false, showsPlay: isHovered, onPlay: play) {
                QTArtworkView(album.artwork, cornerRadius: QTTheme.Radius.artwork, placeholder: .album)
            }
            .frame(width: QTTheme.Metrics.card, height: QTTheme.Metrics.card)
            .padding(.bottom, 6)
            Text(verbatim: album.title)
                .font(QTTheme.Typography.rowTitle)
                .lineLimit(1)
            Text(verbatim: Self.subtitle(album, showsArtist: showsArtist))
                .font(QTTheme.Typography.secondary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: QTTheme.Metrics.card, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { open() }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
        .onHover { hovering in
            isHovered = hovering
            if hovering { QTLiveCatalogStore.shared.prefetch(.album(album)) }
        }
        .contextMenu {
            Button(QTLoc.tr("Play")) { play() }
            Button(QTLoc.tr("Shuffle")) { QTLiveActions.playAlbum(album.id, shuffled: true) }
            if let artist = album.artists.first {
                Divider()
                Button(QTLoc.tr("Go to Artist · %@", artist.name)) {
                    QTNavigator.shared.go(.artist(artist.id ?? artist.name))
                }
            }
            Divider()
            Button(QTLoc.tr("Copy Link")) { QTLiveActions.copyLink("https://music.youtube.com/browse/\(album.id)") }
        }
        .help(album.title)
        .accessibilityLabel(Text(verbatim: "\(album.title), \(Self.subtitle(album))"))
        .accessibilityIdentifier("qt.live.card.album.\(album.id)")
    }

    private func play() { QTLiveActions.playAlbum(album.id, shuffled: false) }
    private func open() { QTNavigator.shared.go(.album(album.id)) }

    /// "Album · Artist" / "Single · 2024" — the kind first, then who made it (or the year when the shelf is the
    /// artist's own).
    static func subtitle(_ album: QTAlbum, showsArtist: Bool = true) -> String {
        let kind: String = switch album.kind {
        case .album: QTLoc.tr("Album")
        case .single: QTLoc.tr("Single", table: .live)
        case .ep: QTLoc.tr("EP", table: .live)
        }
        let artists = album.artists.map(\.name).joined(separator: ", ")
        if showsArtist, !artists.isEmpty { return "\(kind) · \(artists)" }
        if let year = album.year { return "\(kind) · \(year)" }
        return kind
    }
}

struct QTLiveArtistCard: View {
    let artist: QTArtist
    @State private var isHovered = false

    var body: some View {
        Button {
            QTNavigator.shared.go(.artist(artist.id))
        } label: {
            VStack(alignment: .center, spacing: 4) {
                QTLiveCardArtwork(isHovered: isHovered, circular: true, showsPlay: false, onPlay: {}) {
                    QTArtworkView(artist.artwork, cornerRadius: QTTheme.Metrics.card / 2, placeholder: .mic)
                }
                .frame(width: QTTheme.Metrics.card, height: QTTheme.Metrics.card)
                .padding(.bottom, 6)
                Text(verbatim: artist.name)
                    .font(QTTheme.Typography.rowTitle)
                    .lineLimit(1)
                Text(QTLoc.tr("Artist", table: .main))
                    .font(QTTheme.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: QTTheme.Metrics.card)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            if hovering { QTLiveCatalogStore.shared.prefetch(.artist(artist)) }
        }
        .contextMenu {
            Button(QTLoc.tr("Copy Link")) { QTLiveActions.copyLink("https://music.youtube.com/channel/\(artist.id)") }
        }
        .help(artist.name)
        .accessibilityLabel(Text(verbatim: artist.name))
        .accessibilityIdentifier("qt.live.card.artist.\(artist.id)")
    }
}

/// Card artwork: hover zoom inside the clip, soft shadow, optional accent play badge (QTCardPlayBadge).
struct QTLiveCardArtwork<Art: View>: View {
    let isHovered: Bool
    let circular: Bool
    let showsPlay: Bool
    let onPlay: () -> Void
    @ViewBuilder let art: () -> Art
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = circular ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: QTTheme.Radius.artwork, style: .continuous))
        let anim = QTTheme.Motion.animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.4), reduceMotion: reduceMotion)
        art()
            .scaleEffect(isHovered && !reduceMotion ? 1.04 : 1)
            .animation(anim, value: isHovered)
            .clipShape(shape)
            .background(shape.fill(.black.opacity(0.001)).shadow(color: .black.opacity(isHovered ? 0.28 : 0.18), radius: isHovered ? 12 : 8, y: 4))
            .overlay(alignment: .bottomTrailing) {
                if !circular {
                    Button(action: onPlay) { QTCardPlayBadge(icon: .play) }
                        .buttonStyle(.plain)
                        .padding(10)
                        .opacity(showsPlay ? 1 : 0)
                        .offset(y: showsPlay || reduceMotion ? 0 : 4)
                        .animation(QTTheme.Motion.animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.18), reduceMotion: reduceMotion), value: showsPlay)
                        .accessibilityLabel(Text(QTLoc.tr("Play")))
                }
            }
    }
}

/// Actions on live items that need a page fetched first.
@MainActor
enum QTLiveActions {
    static func playAlbum(_ id: String, shuffled: Bool) {
        Task { @MainActor in
            let store = QTLiveCatalogStore.shared
            await store.loadAlbum(id)
            guard let page = store.albumPages[id], let tracks = page.album.tracks, !tracks.isEmpty else { return }
            let source = QTQueueSource(kind: .album, id: id, title: .verbatim(page.album.title))
            if shuffled {
                QTTrackActions.shuffle(tracks, source: source)
            } else if let i = tracks.firstIndex(where: \.availability.isPlayable) {
                QTTrackActions.play(tracks, at: i, source: source)
            }
        }
    }

    static func playPlaylist(_ id: String, title: String, shuffled: Bool) {
        Task { @MainActor in
            let store = QTLiveCatalogStore.shared
            await store.loadPlaylist(id)
            guard let tracks = store.playlist(id)?.tracks, !tracks.isEmpty else { return }
            let source = QTQueueSource(kind: .playlist, id: id, title: .verbatim(title))
            if shuffled {
                QTTrackActions.shuffle(tracks, source: source)
            } else if let i = tracks.firstIndex(where: \.availability.isPlayable) {
                QTTrackActions.play(tracks, at: i, source: source)
            }
        }
    }

    static func copyLink(_ link: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
        QTAppModel.shared.showToast(QTLoc.tr("Link copied"))
    }
}
