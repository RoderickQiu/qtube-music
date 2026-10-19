import AppKit
import QTAuth
import QTCore
import SwiftUI

// Owner: builder "data-live". Loading skeletons, failure and signed-out states for live pages. Native idioms:
// ContentUnavailableView for empty/failure, redacted-style placeholders in the real layout (no spinners in the
// middle of a page), one prominent action. No explanatory copy.

// MARK: - Skeletons

/// Placeholder shapes in the page's real layout while it loads. A slow, quiet pulse; static with Reduce Motion.
struct QTLiveSkeleton: View {
    enum Layout { case shelves, trackList, artist, grid, search }
    let layout: Layout
    var title: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

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
        // The pulse animates opacity only (a transaction-wide repeatForever would also animate first layout).
        .opacity(pulse ? 0.55 : 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)
        .task {
            guard !reduceMotion else { return }
            try? await Task.sleep(for: .milliseconds(50))
            pulse = true
        }
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
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 180), spacing: 20, alignment: .leading), count: 3),
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

// MARK: - Failure

/// A page that couldn't load: one symbol, one line, one action.
struct QTLiveFailureView: View {
    let failure: QTLiveFailure
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } actions: {
            if failure == .sessionExpired {
                Button(QTLoc.tr("Sign In", table: .live)) { QTLiveCatalogStore.shared.signIn() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("qt.live.failure.signIn")
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
        }
    }

    private var symbol: String {
        switch failure {
        case .offline: "wifi.slash"
        case .sessionExpired: "person.crop.circle.badge.exclamationmark"
        case .unavailable: "exclamationmark.triangle"
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

// MARK: - Signed out

/// No session: the app icon, one line, Sign In. "Use Demo Library" is the quiet way to look around first.
struct QTLiveSignedOutView: View {
    @Environment(\.colorScheme) private var scheme
    var auth: QTAuthController { QTLiveCatalogStore.shared.auth }

    var body: some View {
        let isSigningIn = auth.state == .signingIn
        let expired = auth.state == .sessionExpired
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .interpolation(.high)
                .frame(width: 112, height: 112)
                .shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.18), radius: 18, y: 10)
                .accessibilityHidden(true)
            Text(QTLoc.tr(expired ? "Signed out of YouTube Music" : "Sign in to YouTube Music", table: .live))
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.top, 28)
            Button {
                QTLiveCatalogStore.shared.signIn()
            } label: {
                Text(QTLoc.tr("Sign In", table: .live))
                    .frame(minWidth: 140)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            .keyboardShortcut(.defaultAction)
            .disabled(isSigningIn)
            .padding(.top, 22)
            .accessibilityIdentifier("qt.live.signedOut.signIn")
            Button(QTLoc.tr("Use Demo Library", table: .live)) {
                QTLiveCatalogStore.shared.useDemoLibrary()
            }
            .buttonStyle(.link)
            .foregroundStyle(.secondary)
            .padding(.top, 16)
            .accessibilityIdentifier("qt.live.signedOut.demo")
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(y: -24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("qt.live.signedOut")
    }
}
