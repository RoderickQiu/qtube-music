import AppKit
import QTCore
import SwiftUI

// Owner: builder "window". The main window: native NavigationSplitView (sidebar material, traffic lights over the
// sidebar, full-size content) | content with back/forward history | docked inspector; player bar along the
// bottom; Stage over everything when open. Keep the readiness/placement plumbing at the bottom intact.

public struct QTMainWindowView: View {
    @Environment(QTAppModel.self) private var model
    @Environment(QTPlayerModel.self) private var player
    @Environment(\.openSettings) private var openSettings
    @FocusState private var isSearchFocused: Bool

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
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background { QTWindowTint() }
                        .overlay(alignment: .top) { QTToastOverlay() }
                        .inspector(isPresented: $model.isPanelShown) {
                            QTNowPlayingPanel()
                                .inspectorColumnWidth(min: QTTheme.Metrics.panelMinWidth, ideal: QTTheme.Metrics.panelWidth,
                                                      max: QTTheme.Metrics.panelMaxWidth)
                        }
                }
                .toolbar {
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
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            model.isPanelShown.toggle()
                        } label: {
                            Label(QTLoc.tr(model.isPanelShown ? "Hide panel" : "Show panel"), systemImage: QTIcon.sidebar.systemName)
                        }
                        .help("\(QTLoc.tr(model.isPanelShown ? "Hide panel" : "Show panel"))  ⌥⌘N")
                    }
                }
                .navigationTitle("")
                .searchable(text: $model.searchText, placement: .toolbar, prompt: Text(QTLoc.tr("Search music")))
                .searchFocused($isSearchFocused)
                QTPlayerBar()
            }
            if model.surface == .stage {
                QTStageView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .toolbar(model.surface == .stage ? .hidden : .visible, for: .windowToolbar)
        .qtArtworkTint(model.palette)
        .frame(minWidth: 960, minHeight: 600)
        .onChange(of: model.sidebarSelection) { _, item in navigator.sidebarSelectionChanged(to: item) }
        .onChange(of: navigator.searchFocusRequest) { isSearchFocused = true }
        .background(QTWindowAccessor { window in
            window.identifier = QTWindowID.main.identifier
            QTWindowPlacement.place(window, size: model.launch.windowSize ?? QTTheme.Metrics.defaultWindow,
                                    screenName: model.launch.effectiveScreenName)
            QTWindowKeyMonitor.shared.install(model: model)
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
        Group {
            if !query.isEmpty {
                QTSearchResultsView(query: query)
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
            QTAlbumsPage()
        case .section(.artists):
            QTArtistsPage()
        case .section(.history):
            let history = QTTrackCollection.history(player.queue.history)
            if history.tracks.isEmpty {
                QTSectionPlaceholder(item: .history)
            } else {
                QTLibraryView(collection: history, destination: d)
            }
        case .section(.playlist(let id)):
            if let p = catalog.playlists.first(where: { $0.id == id }) {
                QTLibraryView(collection: .playlist(p, catalog: catalog), destination: d)
            } else {
                QTLibraryView(collection: .liked(catalog), destination: d)
            }
        case .section(.explore):
            QTSectionPlaceholder(item: .explore)
        case .album(let title):
            QTLibraryView(collection: .album(title, catalog: catalog), destination: d)
        case .artist(let name):
            QTLibraryView(collection: .artist(name, catalog: catalog), destination: d)
        }
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
