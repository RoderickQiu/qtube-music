import AppKit
import QTCore
import SwiftUI

// Owner: builder "window". The main window: native NavigationSplitView (sidebar material, traffic lights over the
// sidebar, full-size content) | content with back/forward history | docked inspector; floating player bar over
// the bottom of content + inspector; Stage over everything when open. Keep the readiness/placement plumbing at the bottom intact.

public struct QTMainWindowView: View {
    @Environment(QTAppModel.self) private var model
    @Environment(QTPlayerModel.self) private var player
    @Environment(\.openSettings) private var openSettings
    @FocusState private var isSearchFocused: Bool
    /// The in-window Stage covers the browsing UI (see the body); set a moment after the Stage appears.
    @State private var isBrowsingCovered = false
    @State private var coverTask: Task<Void, Never>?

    public init() {
        QTNavigator.shared.attach(QTAppModel.shared)
    }

    public var body: some View {
        @Bindable var model = model
        let navigator = QTNavigator.shared
        ZStack {
            VStack(spacing: 0) {
                NavigationSplitView {
                    QTSidebarView()
                        .navigationSplitViewColumnWidth(min: QTTheme.Metrics.sidebarMinWidth, ideal: QTTheme.Metrics.sidebarWidth, max: 320)
                } detail: {
                    QTContentRouter()
                        // No content minimum, ever: a page's fixed-width pieces (cards, the search top result, row
                        // artwork) would otherwise become the content column's minimum width, and with the panel
                        // open in a narrow window AppKit's split view loops on update-constraints until it throws
                        // (crash reports 2026-10-18/19; a swallowed throw also left Swift's executor bookkeeping
                        // dangling, see docs/architecture.md). Pages lay out in whatever width they get.
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        .background { QTWindowTint() }
                        .overlay(alignment: .top) { QTToastOverlay() }
                        .inspector(isPresented: $model.isPanelShown) {
                            QTNowPlayingPanel()
                                .inspectorColumnWidth(min: QTTheme.Metrics.panelMinWidth, ideal: QTTheme.Metrics.panelWidth,
                                                      max: QTTheme.Metrics.panelMaxWidth)
                        }
                        // The player bar floats over the bottom of the content and the panel (glass on macOS 26,
                        // a material before): the sidebar keeps the window's full height, pages scroll under it.
                        .qtFloatingBottomBar { QTPlayerBar() }
                }
                .toolbar {
                    // Not under the in-window Stage (QTStageTitlebar hides the rest of the toolbar there).
                    if model.surface != .stage {
                        ToolbarItemGroup(placement: .navigation) {
                            Button {
                                navigator.goBack()
                            } label: {
                                Label(QTLoc.tr("Back"), systemImage: QTIcon.chevL.systemName)
                            }
                            .disabled(!navigator.canGoBack)
                            .help("\(QTLoc.tr("Back"))  ⌘[")
                            .accessibilityIdentifier("qt.window.back")
                            Button {
                                navigator.goForward()
                            } label: {
                                Label(QTLoc.tr("Forward"), systemImage: QTIcon.chevR.systemName)
                            }
                            .disabled(!navigator.canGoForward)
                            .help("\(QTLoc.tr("Forward"))  ⌘]")
                            .accessibilityIdentifier("qt.window.forward")
                        }
                        // The search field sits right after back/forward in the content column (prototype), not at the
                        // window's trailing edge over the panel.
                    }
                    // While the panel is shown it closes from its own header (QTPanelHeader); the toolbar only
                    // offers the way back.
                    if !model.isPanelShown, model.surface != .stage {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                withAnimation(QTTheme.Motion.animation(QTTheme.Motion.spring, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) {
                                    model.isPanelShown = true
                                }
                            } label: {
                                Label(QTLoc.tr("Show Panel", table: .desktop), systemImage: QTIcon.sidebar.systemName)
                            }
                            .help("\(QTLoc.tr("Show Panel", table: .desktop))  ⌥⌘N")
                            .accessibilityIdentifier("qt.window.showPanel")
                        }
                    }
                }
                // A real window title (VoiceOver, Mission Control, the Window menu), hidden in the toolbar like
                // Music.app's.
                .navigationTitle(Text(verbatim: QTWindowTitle.title(for: navigator.current, model: model)))
                .toolbar(removing: .title)
                // Search belongs to the content column (prototype: after back/forward; `DefaultToolbarItem` above), so
                // it never reads as the panel's own field and doesn't jump when the panel hides.
                .searchable(text: $model.searchText, placement: .toolbarPrincipal, prompt: Text(QTLoc.tr("Search music")))
                .searchFocused($isSearchFocused)
            }
            // Under the in-window Stage the browsing window is out of reach: VoiceOver, Full Keyboard Access and
            // the mouse only find the Stage (whose own transport is the one that counts). Disabling waits until
            // the Stage has faded in, so nothing greys out visibly on the way.
            .accessibilityHidden(model.surface == .stage)
            .allowsHitTesting(model.surface != .stage)
            .disabled(isBrowsingCovered)
            // …and its clocks (player bar scrubber, panel) stop redrawing under the opaque Stage.
            .environment(\.qtPausesTimeDrivenViews, isBrowsingCovered)
            .onChange(of: model.surface == .stage, initial: true) { _, covered in
                coverTask?.cancel()
                guard covered else { isBrowsingCovered = false; return }
                coverTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(450))
                    guard !Task.isCancelled, model.surface == .stage else { return }
                    isBrowsingCovered = true
                }
            }
            if model.surface == .stage {
                QTStageView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        // The in-window Stage keeps the window's own title bar and toolbar; QTStageTitlebar (Stage/) hides its items.
        .overlay { QTLyricsLabOverlay() }
        // The app's accent: the song's colour, or the system accent (Settings › Accent colour).
        .qtArtworkTint(model.palette)
        .frame(minWidth: 960, minHeight: 600)
        // New / Edit Playlist sheet and the Delete Playlist question (Library/QTPlaylistSheets.swift).
        .qtPlaylistSheets()
        .onChange(of: model.sidebarSelection) { _, item in navigator.sidebarSelectionChanged(to: item) }
        .onChange(of: navigator.searchFocusRequest) { isSearchFocused = true }
        .background(QTWindowAccessor { window in
            window.identifier = QTWindowID.main.identifier
            // The user's own size and position win (AppKit restores the autosaved frame); only dev/screenshot
            // launches (`-qt.screen`, `-qt.window`) and a first launch are placed.
            if QTWindowPlacement.shouldPlaceMainWindow(window, launch: model.launch) {
                QTWindowPlacement.place(window, size: model.launch.windowSize ?? QTTheme.Metrics.defaultWindow,
                                        screenName: model.launch.effectiveScreenName)
            }
            QTWindowKeyMonitor.shared.install(model: model)
            // One stable panel width, live or demo (see QTInspectorWidthKeeper).
            QTInspectorWidthKeeper.attach(to: window, launch: model.launch)
        })
        .task {
            model.applyAppearance()
            await model.applyLaunchPlayback()
            if model.launch.extraWindows.contains(.settings) { openSettings() }
            QTReadiness.shared.markLaunchFinished()
        }
    }
}

/// Routes the current destination (or an active search) to a content view.
struct QTContentRouter: View {
    @Environment(QTAppModel.self) private var model
    @Environment(QTPlayerModel.self) private var player

    var body: some View {
        let navigator = QTNavigator.shared
        let query = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let live = QTLiveCatalogStore.shared
        Group {
            if !query.isEmpty, live.mode == .mock || live.isLive {
                // One search page for the demo catalog and YouTube Music (QTBrowse.service).
                QTSearchResultsView(query: query)
            } else if live.handles(navigator.current) {
                // data-live: YouTube Music pages, signed-out and loading states.
                QTLivePage(destination: navigator.current)
                    .id(navigator.current.stateKey)
            } else {
                page(navigator.current)
                    .id(navigator.current.stateKey)
            }
        }
    }

    @ViewBuilder
    private func page(_ d: QTDestination) -> some View {
        let catalog = model.catalog
        switch d {
        case .section(.home):
            QTHomeView()
        case .section(.liked):
            QTLibraryView(collection: .liked(catalog), destination: d)
        case .section(.songs):
            QTLibraryView(collection: .songs(catalog), destination: d)
        case .section(.albums):
            QTLibraryAlbumsPage()
        case .section(.artists):
            QTLibraryArtistsPage()
        case .section(.history):
            let history = QTTrackCollection.history(player.queue.history)
            if history.tracks.isEmpty {
                QTSectionPlaceholder(item: .history)
            } else {
                QTLibraryView(collection: history, destination: d)
            }
        case .section(.uploads):
            QTUploadsPage()
        case .section(.playlist(let id)):
            // Through the store: playlists made here and renames count too.
            if let p = QTLiveCatalogStore.shared.playlist(id) {
                QTLibraryView(collection: .playlist(p, catalog: catalog), destination: d)
            } else {
                QTLibraryView(collection: .liked(catalog), destination: d)
            }
        case .section(.explore):
            QTExploreView()
        // Browse pages: the same views the live library uses (QTBrowsePages.swift).
        case .album(let key):
            QTAlbumPageView(key: key)
        case .artist(let key):
            QTArtistPageView(key: key)
        case .mood(let chip):
            QTMoodPageView(chip: chip)
        case .shelf(let shelf):
            QTLibraryView(collection: .shelf(shelf), destination: d)
        }
    }
}

/// The main window's title: what the content column shows (the toolbar hides it; Accessibility, Mission Control
/// and the Window menu read it).
@MainActor
enum QTWindowTitle {
    static func title(for destination: QTDestination, model: QTAppModel) -> String {
        let query = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty { return QTLoc.tr("Results for “%@”", table: .main, query) }
        let navigator = QTNavigator.shared
        switch destination {
        case .section(.playlist(let id)):
            return (model.catalog.playlists.first { $0.id == id } ?? QTLiveCatalogStore.shared.playlist(id))?.title.resolved
                ?? QTSidebarView.title(for: .playlist(id))
        case .section(let item):
            return QTSidebarView.title(for: item)
        case .mood(let chip):
            return chip.title.resolved
        case .shelf(let shelf):
            return shelf.title.resolved
        case .album(let key):
            return navigator.pageTitle(for: destination) ?? (isBrowseID(key) ? QTLoc.tr("Album") : key)
        case .artist(let key):
            return navigator.pageTitle(for: destination) ?? (isBrowseID(key) ? QTLoc.tr("Artist", table: .main) : key)
        }
    }

    /// `MPREb_…`, `UC…`, uploads' `FEmusic_library_privately_owned_…` and friends: ids, not names to show.
    static func isBrowseID(_ key: String) -> Bool {
        (key.hasPrefix("MPRE") || key.hasPrefix("UC") || key.hasPrefix("MPLA") || QTUploads.isUploadID(key))
            && !key.contains(" ") && key.count >= 12
    }
}

/// Sections that need the data layer (M3): icon + title only (no explanatory copy).
struct QTSectionPlaceholder: View {
    let item: QTSidebarItem

    var body: some View {
        ContentUnavailableView(QTSidebarView.title(for: item), systemImage: QTSidebarView.icon(for: item).systemName)
            .accessibilityIdentifier("qt.window.placeholder.\(item.argument)")
    }
}

/// Subtle window tint from the current artwork (draft §3 "Window tint"): a soft wash of the artwork accent at the
/// top of the content column. Off under Increase Contrast; cross-fades between tracks.
struct QTWindowTint: View {
    @Environment(QTAppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let palette = model.palette
        let accent = palette.map { Color(qt: scheme == .dark ? $0.accentOnDark : $0.accentOnLight) } ?? .clear
        LinearGradient(stops: [
            .init(color: accent.opacity(scheme == .dark ? 0.14 : 0.10), location: 0),
            .init(color: accent.opacity(0.03), location: 0.45),
            .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom)
        .opacity(contrast == .increased || palette == nil ? 0 : 1)
        .animation(QTTheme.Motion.animation(.easeInOut(duration: 0.9), reduceMotion: reduceMotion), value: palette)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
