import AppKit
import QTAuth
import QTCore
import SwiftUI

// Owner: builder "data-live". Loading skeletons, failure and guest (sign-in) states for live pages. Native idioms:
// ContentUnavailableView for empty/failure, redacted-style placeholders in the real layout (no spinners in the
// middle of a page), one prominent action. No explanatory copy.

// MARK: - Skeletons

/// Placeholder shapes in the page's real layout while it loads. A slow, quiet pulse; static with Reduce Motion.
struct QTLiveSkeleton: View {
    enum Layout { case shelves, trackList, artist, grid, search }
    let layout: Layout
    var title: String?

    var body: some View {
        // Takes exactly the space it's offered (never asks the window for its own, wider ideal size); top-leading
        // and clipped, so rows wider than the column run off its right edge like the real shelves.
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 0) {
                switch layout {
                case .shelves: shelves
                case .trackList: trackList
                case .artist: artist
                case .grid: grid
                case .search: search
                }
            }
            .frame(width: geo.size.width, alignment: .leading)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
        }
        .qtSkeletonPulse()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(QTLoc.tr("Loading", table: .live)))
        .accessibilityIdentifier("qt.live.skeleton")
    }

    private var fill: some ShapeStyle { .fill.secondary }

    private func bar(_ width: CGFloat, _ height: CGFloat = 12) -> some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous).fill(fill).frame(width: width, height: height)
    }

    private func tile(_ w: CGFloat, _ h: CGFloat, circle: Bool = false) -> some View {
        Group {
            if circle {
                Circle().fill(fill)
            } else {
                RoundedRectangle(cornerRadius: QTTheme.Radius.artwork, style: .continuous).fill(fill)
            }
        }
        .frame(width: w, height: h)
    }

    @ViewBuilder private var pageTitle: some View {
        if let title {
            Text(verbatim: title).font(QTTheme.Typography.pageTitle)
        } else {
            bar(260, 30)
        }
    }

    private var shelves: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                pageTitle
                HStack(spacing: QTTheme.Spacing.xs) {
                    ForEach(0..<6, id: \.self) { i in
                        Capsule().fill(fill).frame(width: [64, 78, 70, 58, 84, 66][i], height: 28)
                    }
                }
            }
            .padding(.top, 40)
            .padding(.horizontal, QTTheme.Spacing.gutter)
            ForEach(0..<3, id: \.self) { row in
                VStack(alignment: .leading, spacing: 14) {
                    bar([150, 120, 180][row], 18).padding(.horizontal, QTTheme.Spacing.gutter)
                    HStack(alignment: .top, spacing: QTTheme.Spacing.shelfGap) {
                        ForEach(0..<7, id: \.self) { _ in
                            VStack(alignment: .leading, spacing: 8) {
                                tile(QTTheme.Metrics.card, QTTheme.Metrics.card)
                                bar(120)
                                bar(80, 10)
                            }
                        }
                    }
                    .padding(.horizontal, QTTheme.Spacing.gutter)
                }
                .padding(.top, QTTheme.Spacing.shelfSpacing)
            }
        }
    }

    private var trackList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: 28) {
                tile(QTTheme.Metrics.playlistTile, QTTheme.Metrics.playlistTile)
                VStack(alignment: .leading, spacing: 10) {
                    bar(60, 10)
                    if let title {
                        Text(verbatim: title).font(QTTheme.Typography.pageTitle).lineLimit(1)
                    } else {
                        bar(280, 30)
                    }
                    bar(130)
                    HStack(spacing: 10) {
                        Capsule().fill(fill).frame(width: 86, height: 30)
                        Capsule().fill(fill).frame(width: 96, height: 30)
                    }
                    .padding(.top, 10)
                }
            }
            .padding(.horizontal, QTTheme.Spacing.gutter)
            .padding(.top, 36)
            .padding(.bottom, 28)
            rows(12)
        }
    }

    private func rows(_ n: Int) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<n, id: \.self) { i in
                HStack(spacing: 14) {
                    tile(QTTheme.Metrics.rowArtwork, QTTheme.Metrics.rowArtwork)
                    VStack(alignment: .leading, spacing: 6) {
                        bar(CGFloat([210, 160, 240, 180, 200, 150][i % 6]))
                        bar(CGFloat([110, 90, 130, 100, 120, 80][i % 6]), 10)
                    }
                    Spacer()
                    bar(CGFloat([140, 110, 160, 120][i % 4]), 10)
                    Spacer().frame(width: 60)
                    bar(34, 10)
                }
                .frame(height: QTTheme.Metrics.tableRowHeight)
                .padding(.horizontal, QTTheme.Spacing.gutter)
            }
        }
    }

    private var artist: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: 28) {
                tile(176, 176, circle: true)
                VStack(alignment: .leading, spacing: 10) {
                    bar(60, 10)
                    if let title { Text(verbatim: title).font(QTTheme.Typography.pageTitle) } else { bar(240, 30) }
                    bar(150)
                    HStack(spacing: 10) {
                        Capsule().fill(fill).frame(width: 86, height: 30)
                        Capsule().fill(fill).frame(width: 96, height: 30)
                    }
                    .padding(.top, 10)
                }
            }
            .padding(.horizontal, QTTheme.Spacing.gutter)
            .padding(.top, 40)
            bar(90, 18).padding(.horizontal, QTTheme.Spacing.gutter).padding(.top, QTTheme.Spacing.shelfSpacing)
            quickRows.padding(.top, 14)
            bar(110, 18).padding(.horizontal, QTTheme.Spacing.gutter).padding(.top, QTTheme.Spacing.shelfSpacing)
            HStack(spacing: QTTheme.Spacing.shelfGap) {
                ForEach(0..<7, id: \.self) { _ in tile(QTTheme.Metrics.card, QTTheme.Metrics.card) }
            }
            .padding(.horizontal, QTTheme.Spacing.gutter)
            .padding(.top, 14)
        }
    }

    private var quickRows: some View {
        // No grid minimum (it would become the content column's minimum width; see QTQuickPicks).
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 20, alignment: .leading), count: 3),
                  alignment: .leading, spacing: 4) {
            ForEach(0..<6, id: \.self) { i in
                HStack(spacing: 14) {
                    tile(QTTheme.Metrics.quickPickArtwork, QTTheme.Metrics.quickPickArtwork)
                    VStack(alignment: .leading, spacing: 6) {
                        bar(CGFloat([150, 120, 170][i % 3]))
                        bar(CGFloat([90, 70, 100][i % 3]), 10)
                    }
                }
                .padding(6)
            }
        }
        .padding(.horizontal, QTTheme.Spacing.gutter)
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: 24) {
            pageTitle
            LazyVGrid(columns: [GridItem(.adaptive(minimum: QTTheme.Metrics.card, maximum: QTTheme.Metrics.card + 24),
                                         spacing: QTTheme.Spacing.shelfGap, alignment: .top)],
                      alignment: .leading, spacing: 28) {
                ForEach(0..<12, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 8) {
                        tile(QTTheme.Metrics.card, QTTheme.Metrics.card)
                        bar(110)
                        bar(70, 10)
                    }
                }
            }
        }
        .padding(.horizontal, QTTheme.Spacing.gutter)
        .padding(.top, 40)
    }

    private var search: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageTitle
                .padding(.horizontal, QTTheme.Spacing.gutter)
                .padding(.top, 32)
            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 14) {
                    bar(90, 14)
                    tile(240, 240)
                }
                VStack(alignment: .leading, spacing: 14) {
                    bar(60, 14)
                    VStack(spacing: 4) {
                        ForEach(0..<4, id: \.self) { i in
                            HStack(spacing: 14) {
                                tile(QTTheme.Metrics.quickPickArtwork, QTTheme.Metrics.quickPickArtwork)
                                VStack(alignment: .leading, spacing: 6) {
                                    bar(CGFloat([200, 150, 230, 170][i]))
                                    bar(CGFloat([100, 80, 120, 90][i]), 10)
                                }
                                Spacer()
                            }
                            .padding(6)
                        }
                    }
                }
            }
            .padding(.horizontal, QTTheme.Spacing.gutter)
            .padding(.top, 28)
        }
    }
}

/// The skeletons' slow, quiet pulse; static with Reduce Motion.
private struct QTSkeletonPulse: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    func body(content: Content) -> some View {
        content
            // Opacity only (a transaction-wide repeatForever would also animate first layout).
            .opacity(pulse ? 0.55 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)
            .task {
                guard !reduceMotion else { return }
                try? await Task.sleep(for: .milliseconds(50))
                pulse = true
            }
    }
}

extension View {
    func qtSkeletonPulse() -> some View { modifier(QTSkeletonPulse()) }
}

// MARK: - Home placeholders

// Home loads in sections: the greeting is real at once, the mood chips and the shelves each swap their own
// placeholder for content in place. The placeholders are built from the real views' metrics (a hidden chip, hidden
// text in the real fonts, `QTSongShelfLayout`), so nothing moves when the content arrives.

/// Mood chips while Home's feed loads: hidden real chips with a capsule each, so size, spacing and wrapping match.
/// The hidden titles are YouTube Music's usual ten moods in the interface language (never shown).
struct QTMoodChipsSkeleton: View {
    private static var words: [String] {
        switch QTLoc.language {
        case .en: ["Energize", "Workout", "Relax", "Feel good", "Party", "Commute", "Focus", "Romance", "Sad", "Sleep"]
        case .zhHans: ["焕活能量", "健身", "休闲放松", "轻松愉悦", "派对", "通勤", "专注", "浪漫", "伤心难过", "睡眠"]
        }
    }

    var body: some View {
        QTChipFlow(spacing: 10) {
            ForEach(Self.words, id: \.self) { word in
                Toggle(isOn: .constant(false)) { Text(verbatim: word) }
                    .toggleStyle(QTChipToggleStyle())
                    .hidden()
                    .overlay { Capsule(style: .continuous).fill(.fill.secondary) }
            }
        }
        .qtSkeletonPulse()
        .accessibilityHidden(true)
    }
}

/// Home's shelves while they load: a song shelf in its paged four-row grid, then two card rows.
struct QTHomeShelvesSkeleton: View {
    @State private var width: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            shelf(title: 170) { songGrid }
            shelf(title: 130) { cards }
            shelf(title: 190) { cards }
        }
        .qtSkeletonPulse()
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(QTLoc.tr("Loading", table: .live)))
        .accessibilityIdentifier("qt.live.skeleton")
    }

    private var fill: some ShapeStyle { .fill.secondary }

    /// A bar the height of one line of `font`, so the rows keep the real text's height.
    private func line(_ font: Font, width: CGFloat, height: CGFloat) -> some View {
        Text(verbatim: "Placeholder")
            .font(font)
            .hidden()
            .frame(width: width, alignment: .leading)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2, style: .continuous).fill(fill).frame(width: width, height: height)
            }
    }

    private func tile(_ size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: QTTheme.Radius.artwork, style: .continuous).fill(fill).frame(width: size, height: size)
    }

    private func shelf<Content: View>(title: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            line(QTTheme.Typography.shelfTitle, width: title, height: 18)
                .padding(.horizontal, QTTheme.Spacing.gutter)
            content()
        }
        .padding(.top, QTTheme.Spacing.shelfSpacing)
    }

    /// `QTQuickPickRow`'s geometry: 6 pt padding, 52 pt art, 14 pt gap, title over artist.
    private var songGrid: some View {
        let layout = QTSongShelfLayout(width: width, tracks: 20, ranked: false)
        return HStack(alignment: .top, spacing: QTSongShelfLayout.columnSpacing) {
            ForEach(0..<layout.perPage, id: \.self) { c in
                VStack(alignment: .leading, spacing: QTSongShelfLayout.rowSpacing) {
                    ForEach(0..<layout.rows, id: \.self) { r in
                        let i = c * layout.rows + r
                        HStack(spacing: 14) {
                            tile(QTTheme.Metrics.quickPickArtwork)
                            VStack(alignment: .leading, spacing: 2) {
                                line(QTTheme.Typography.rowTitle, width: CGFloat([150, 120, 170, 135][i % 4]), height: 12)
                                line(QTTheme.Typography.secondary, width: CGFloat([90, 70, 105, 80][i % 4]), height: 10)
                            }
                        }
                        .padding(6)
                    }
                }
                .frame(width: layout.columnWidth, alignment: .leading)
            }
        }
        .padding(.horizontal, QTTheme.Spacing.gutter)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    /// `QTHomeCard`'s geometry: square art, 6 + 4 pt, title, artist.
    private var cards: some View {
        HStack(alignment: .top, spacing: QTTheme.Spacing.shelfGap) {
            ForEach(0..<8, id: \.self) { i in
                VStack(alignment: .leading, spacing: 4) {
                    tile(QTTheme.Metrics.card).padding(.bottom, 6)
                    line(QTTheme.Typography.rowTitle, width: CGFloat([120, 100, 135, 110][i % 4]), height: 12)
                    line(QTTheme.Typography.secondary, width: CGFloat([80, 65, 90, 70][i % 4]), height: 10)
                }
            }
        }
        .padding(.horizontal, QTTheme.Spacing.gutter)
        .padding(.bottom, 10)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
    }
}

// MARK: - Failure

/// A page that couldn't load: one symbol, one line, one action.
struct QTLiveFailureView: View {
    let failure: QTLiveFailure
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } actions: {
            if failure == .sessionExpired || failure == .botCheck {
                // A bot check usually clears once signed in; signed in already, it can only wait (Try Again).
                if failure == .botCheck, QTLiveCatalogStore.shared.hasLibrary {
                    Button(QTLoc.tr("Try Again", table: .live), action: retry)
                        .controlSize(.large)
                        .accessibilityIdentifier("qt.live.failure.retry")
                } else {
                    QTSignInButton(prominent: true)
                        .controlSize(.large)
                        .accessibilityIdentifier("qt.live.failure.signIn")
                }
            } else {
                Button(QTLoc.tr("Try Again", table: .live), action: retry)
                    .controlSize(.large)
                    .keyboardShortcut("r", modifiers: .command)
                    .accessibilityIdentifier("qt.live.failure.retry")
            }
        }
        .accessibilityIdentifier("qt.live.failure")
    }

    private var title: String {
        switch failure {
        case .offline: QTLoc.tr("You’re offline", table: .live)
        case .sessionExpired: QTLoc.tr("Signed out of YouTube Music", table: .live)
        case .unavailable: QTLoc.tr("Couldn’t load this page", table: .live)
        case .botCheck: QTLoc.tr("YouTube wants to check this connection", table: .live)
        }
    }

    private var symbol: String {
        switch failure {
        case .offline: "wifi.slash"
        case .sessionExpired: "person.crop.circle.badge.exclamationmark"
        case .unavailable: "exclamationmark.triangle"
        case .botCheck: "hand.raised"
        }
    }
}

/// Phase switch for a live page: skeleton → content, or the failure state.
struct QTLivePhaseView<Content: View>: View {
    let phase: QTLivePhase
    let skeleton: QTLiveSkeleton
    let retry: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        switch QTLiveCatalogStore.shared.pinnedPhase ?? phase {
        case .loaded: content()
        case .failed(let failure): QTLiveFailureView(failure: failure, retry: retry)
        case .idle, .loading: skeleton
        }
    }
}

// MARK: - Guest

/// Guest mode on a library place (Liked Songs, Songs, Albums, Artists, Uploads): the place's symbol, one line, Sign In.
struct QTLiveSignInPrompt: View {
    let destination: QTDestination
    var auth: QTAuthController { QTLiveCatalogStore.shared.auth }

    var body: some View {
        ContentUnavailableView {
            Label(Self.title(for: destination, expired: auth.state == .sessionExpired), systemImage: symbol)
        } actions: {
            QTSignInButton(prominent: true)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("qt.live.guest.signIn")
        }
        .accessibilityIdentifier("qt.live.guest")
    }

    static func title(for destination: QTDestination, expired: Bool) -> String {
        if expired { return QTLoc.tr("Signed out of YouTube Music", table: .live) }
        if destination == .section(.liked) || destination == .section(.playlist("LM")) {
            return QTLoc.tr("Sign in to see your liked songs", table: .live)
        }
        if destination == .section(.uploads) { return QTLoc.tr("Sign in to see your uploads", table: .live) }
        return QTLoc.tr("Sign in to see your library", table: .live)
    }

    private var symbol: String {
        switch destination {
        case .section(let item): QTSidebarView.icon(for: item).systemName
        default: "person.crop.circle"
        }
    }
}

/// "Sign In": opens Google's sign-in window (the one sign-in path; disabled while that window is open).
struct QTSignInButton: View {
    var prominent = false
    var auth: QTAuthController { QTLiveCatalogStore.shared.auth }

    var body: some View {
        let button = Button(QTLoc.tr("Sign In", table: .live)) { QTLiveCatalogStore.shared.signIn() }
            .disabled(auth.state == .signingIn)
        if prominent { button.buttonStyle(.borderedProminent) } else { button }
    }
}

/// Guest mode's offer to sign in when the user reaches for an account feature (a like, adding to a playlist):
/// a toast with Sign In — never a local stand-in for the account's library.
@MainActor
enum QTAccountGate {
    /// True when the action may go ahead; in guest mode shows the sign-in toast and returns false.
    static func allows(_ feature: Feature, model: QTAppModel? = nil, store: QTLiveCatalogStore = .shared) -> Bool {
        guard store.isGuest else { return true }
        (model ?? .shared).showToast(feature.message, actionTitle: QTLoc.tr("Sign In", table: .live)) {
            QTLiveCatalogStore.shared.signIn()
        }
        return false
    }

    enum Feature {
        case like, addToPlaylist

        var message: String {
            switch self {
            case .like: QTLoc.tr("Sign in to like songs", table: .live)
            case .addToPlaylist: QTLoc.tr("Sign in to add songs to playlists", table: .live)
            }
        }
    }
}
