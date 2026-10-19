import QTCore
import QTInnerTube
import SwiftUI

// Owner: builder "data-live". Artist page: hero (the artist's wide photo when YouTube Music has one, else a round
// portrait), Play / Shuffle, top Songs, then the server's own rows in order — Albums, Singles & EPs, Videos (the
// draft's "Videos row next to Songs and Albums"), live performances, playlists, fans also like. Music only.

struct QTLiveArtistView: View {
    let key: String

    var body: some View {
        let store = QTLiveCatalogStore.shared
        QTLivePhaseView(phase: store.artistPhases[key] ?? .idle, skeleton: QTLiveSkeleton(layout: .artist),
                        retry: { Task { await store.loadArtist(key, force: true) } }) {
            if let page = store.artistPages[key] {
                QTLiveArtistContent(page: page)
            }
        }
        .task(id: key) { await store.loadArtist(key) }
    }
}

struct QTLiveArtistContent: View {
    let page: QTArtistPage
    @Environment(QTAppModel.self) private var model
    @Environment(\.colorSchemeContrast) private var contrast

    /// Wide photo → hero banner; square → portrait.
    private var isWide: Bool {
        guard let best = page.artist.artwork.max(by: { ($0.width ?? 0) < ($1.width ?? 0) }),
              let w = best.width, let h = best.height, h > 0 else { return false }
        return Double(w) / Double(h) > 1.5
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                if isWide { hero } else { portraitHeader }
                if !page.songs.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(QTLoc.tr("Songs"))
                            .font(QTTheme.Typography.shelfTitle)
                            .accessibilityAddTraits(.isHeader)
                            .padding(.horizontal, QTTheme.Spacing.gutter)
                        QTQuickPicks(tracks: page.songs)
                    }
                    .padding(.top, QTTheme.Spacing.shelfSpacing)
                }
                ForEach(page.shelves) { shelf in
                    QTHomeShelf(shelf: shelf)
                        .padding(.top, QTTheme.Spacing.shelfSpacing)
                }
                if let about = page.description, !about.isEmpty {
                    Text(verbatim: about)
                        .font(QTTheme.Typography.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                        .frame(maxWidth: 640, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.horizontal, QTTheme.Spacing.gutter)
                        .padding(.top, QTTheme.Spacing.shelfSpacing)
                }
            }
            .padding(.bottom, 48)
        }
        .accessibilityIdentifier("qt.live.artist")
    }

    // MARK: Header

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            QTArtworkView(page.artist.artwork, cornerRadius: 0, placeholder: .mic)
                .frame(maxWidth: .infinity)
                .frame(height: 360)
                .overlay {
                    // Legibility for the name, not decoration.
                    LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: .black.opacity(0.62), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .clipped()
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: page.artist.name)
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 2)
                    .accessibilityAddTraits(.isHeader)
                if let audience = page.audience {
                    Text(verbatim: audience)
                        .font(QTTheme.Typography.secondary)
                        .foregroundStyle(.white.opacity(0.85))
                }
                actions.padding(.top, 12)
            }
            .padding(.horizontal, QTTheme.Spacing.gutter)
            .padding(.bottom, 28)
            .environment(\.colorScheme, .dark)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("qt.live.artist.hero")
    }

    private var portraitHeader: some View {
        HStack(alignment: .bottom, spacing: 28) {
            QTArtworkView(page.artist.artwork, cornerRadius: 88, placeholder: .mic)
                .frame(width: 176, height: 176)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.25), radius: 12, y: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(QTLoc.tr("Artist", table: .main))
                    .font(QTTheme.Typography.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(verbatim: page.artist.name)
                    .font(QTTheme.Typography.pageTitle)
                    .lineLimit(1)
                    .padding(.top, 4)
                    .padding(.bottom, 6)
                    .accessibilityAddTraits(.isHeader)
                if let audience = page.audience {
                    Text(verbatim: audience).foregroundStyle(.secondary)
                }
                actions.padding(.top, 18)
            }
        }
        .padding(.horizontal, QTTheme.Spacing.gutter)
        .padding(.top, 40)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("qt.live.artist.header")
    }

    private var actions: some View {
        let playable = page.songs.filter(\.availability.isPlayable)
        let source = QTQueueSource(kind: .artist, id: page.artist.id, title: .verbatim(page.artist.name))
        return HStack(spacing: 10) {
            Button {
                if let i = page.songs.firstIndex(where: \.availability.isPlayable) {
                    QTTrackActions.play(page.songs, at: i, source: source)
                }
            } label: {
                Label(QTLoc.tr("Play"), systemImage: QTIcon.play.systemName)
            }
            .buttonStyle(.borderedProminent)
            .tint(QTTheme.Colors.accent(model.palette, scheme: .light, increaseContrast: contrast == .increased))
            .accessibilityIdentifier("qt.live.artist.play")
            Button {
                QTTrackActions.shuffle(page.songs, source: source)
            } label: {
                Label(QTLoc.tr("Shuffle"), systemImage: QTIcon.shuffle.systemName)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("qt.live.artist.shuffle")
        }
        .controlSize(.large)
        .buttonBorderShape(.capsule)
        .disabled(playable.isEmpty)
    }
}
