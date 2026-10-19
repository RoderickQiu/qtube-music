import AppKit
import QTCore
import SwiftUI

// Owner: builder "window". The main window: sidebar | content | docked inspector, player bar along the bottom,
// Stage over everything when open. Keep the readiness/placement plumbing at the bottom intact.

public struct QTMainWindowView: View {
    @Environment(QTAppModel.self) private var model
    @Environment(QTPlayerModel.self) private var player
    @Environment(\.openSettings) private var openSettings

    public init() {}

    public var body: some View {
        @Bindable var model = model
        ZStack {
            VStack(spacing: 0) {
                NavigationSplitView {
                    QTSidebarView()
                        .navigationSplitViewColumnWidth(min: QTTheme.Metrics.sidebarMinWidth, ideal: QTTheme.Metrics.sidebarWidth, max: 320)
                } detail: {
                    QTContentRouter()
                        .inspector(isPresented: $model.isPanelShown) {
                            QTNowPlayingPanel()
                                .inspectorColumnWidth(min: QTTheme.Metrics.panelMinWidth, ideal: QTTheme.Metrics.panelWidth,
                                                      max: QTTheme.Metrics.panelMaxWidth)
                        }
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            model.isPanelShown.toggle()
                        } label: {
                            Label(QTLoc.tr(model.isPanelShown ? "Hide panel" : "Show panel"), systemImage: QTIcon.sidebar.systemName)
                        }
                        .help("\(QTLoc.tr(model.isPanelShown ? "Hide panel" : "Show panel"))  ⌥⌘N")
                    }
                }
                .searchable(text: $model.searchText, placement: .toolbar, prompt: Text(QTLoc.tr("Search music")))
                QTPlayerBar()
            }
            if model.surface == .stage {
                QTStageView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .toolbar(model.surface == .stage ? .hidden : .visible, for: .windowToolbar)
        .overlay(alignment: .top) { QTToastOverlay() }
        .qtArtworkTint(model.palette)
        .frame(minWidth: 960, minHeight: 600)
        .background(QTWindowAccessor { window in
            window.identifier = QTWindowID.main.identifier
            QTWindowPlacement.place(window, size: model.launch.windowSize ?? QTTheme.Metrics.defaultWindow,
                                    screenName: model.launch.effectiveScreenName)
        })
        .task {
            model.applyAppearance()
            await model.applyLaunchPlayback()
            if model.launch.extraWindows.contains(.settings) { openSettings() }
            QTReadiness.shared.markLaunchFinished()
        }
    }
}

/// Routes the sidebar selection to a content view.
struct QTContentRouter: View {
    @Environment(QTAppModel.self) private var model

    var body: some View {
        switch model.sidebarSelection {
        case .home:
            QTHomeView()
        case .liked, .songs:
            QTLibraryView(playlist: model.catalog.liked)
        case .playlist(let id):
            if let p = model.catalog.playlists.first(where: { $0.id == id }) {
                QTLibraryView(playlist: p)
            } else {
                QTLibraryView(playlist: model.catalog.liked)
            }
        case .explore, .albums, .artists, .history:
            QTSectionPlaceholder(item: model.sidebarSelection)
        }
    }
}

/// Sections not built yet in M1: icon + title only (no explanatory copy).
struct QTSectionPlaceholder: View {
    let item: QTSidebarItem

    var body: some View {
        ContentUnavailableView(QTSidebarView.title(for: item), systemImage: QTSidebarView.icon(for: item).systemName)
    }
}
