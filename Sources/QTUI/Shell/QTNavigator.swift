import Foundation
import Observation
import QTCore

/// Where the main window's content column is. Sidebar sections plus pages you reach from them
/// (an album or artist from a song's context menu). Search is an overlay while the search field has text,
/// not a history entry — like Music.app.
public enum QTDestination: Hashable, Sendable {
    case section(QTSidebarItem)
    /// Album page, by album title (mock catalog albums have no ids yet).
    case album(String)
    /// Artist page, by artist name.
    case artist(String)
    /// A mood or genre page from Explore.
    case mood(QTMoodChip)

    public var sidebarItem: QTSidebarItem? {
        if case .section(let item) = self { return item }
        return nil
    }

    /// Stable key for per-page state (scroll position, filter, sort).
    public var stateKey: String {
        switch self {
        case .section(let item): "section:\(item.argument)"
        case .album(let title): "album:\(title)"
        case .artist(let name): "artist:\(name)"
        case .mood(let chip): "mood:\(chip.id)"
        }
    }
}

/// Back/forward history for the content column. Remembers each page's scroll position, filter and sort,
/// so going back returns you to exactly where you were (draft §3, §7 "Remembers position").
/// One per process; the toolbar, sidebar, ⌘[ / ⌘] and context menus all go through it.
@MainActor
@Observable
public final class QTNavigator {
    public static let shared = QTNavigator()

    public private(set) var current: QTDestination = .section(.home)
    public private(set) var backStack: [QTDestination] = []
    public private(set) var forwardStack: [QTDestination] = []

    /// Incremented by ⌘F; the visible filter field takes focus.
    public private(set) var filterFocusRequest = 0
    /// Incremented by ⌘K; the toolbar search field takes focus.
    public private(set) var searchFocusRequest = 0

    @ObservationIgnored private var listStates: [String: QTTrackListState] = [:]
    @ObservationIgnored private var scrollOffsets: [String: CGFloat] = [:]
    @ObservationIgnored private weak var model: QTAppModel?
    @ObservationIgnored private var isSyncingSidebar = false

    static let historyLimit = 64

    public init() {}

    /// Connects to the app model; the current page starts at the model's sidebar selection.
    public func attach(_ model: QTAppModel) {
        guard self.model !== model else { return }
        self.model = model
        current = .section(model.sidebarSelection)
        backStack = []
        forwardStack = []
        QTWindowLaunchHooks.apply(model.launch, model: model, navigator: self)
    }

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }

    /// Pushes a new page (no-op when it's the current one). Clears an active search so the page is visible.
    public func go(_ destination: QTDestination) {
        model?.searchText = ""
        guard destination != current else { return }
        backStack.append(current)
        if backStack.count > Self.historyLimit { backStack.removeFirst(backStack.count - Self.historyLimit) }
        forwardStack.removeAll()
        current = destination
        syncSidebar()
    }

    public func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(current)
        current = previous
        model?.searchText = ""
        syncSidebar()
    }

    public func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(current)
        current = next
        model?.searchText = ""
        syncSidebar()
    }

    /// Called when `QTAppModel.sidebarSelection` changes (sidebar click, ⌘1–4, other areas).
    public func sidebarSelectionChanged(to item: QTSidebarItem) {
        guard !isSyncingSidebar, current != .section(item) else { return }
        go(.section(item))
    }

    public func requestFilterFocus() { filterFocusRequest += 1 }
    public func requestSearchFocus() { searchFocusRequest += 1 }

    // MARK: Per-page state

    /// Filter / sort / selection / scroll for a track list, kept across navigation.
    public func listState(for key: String) -> QTTrackListState {
        if let s = listStates[key] { return s }
        let s = QTTrackListState()
        listStates[key] = s
        return s
    }

    public func scrollOffset(for destination: QTDestination) -> CGFloat { scrollOffsets[destination.stateKey] ?? 0 }
    public func setScrollOffset(_ y: CGFloat, for destination: QTDestination) { scrollOffsets[destination.stateKey] = y }

    private func syncSidebar() {
        guard let model, let item = current.sidebarItem, model.sidebarSelection != item else { return }
        isSyncingSidebar = true
        model.sidebarSelection = item
        isSyncingSidebar = false
    }
}

/// Sort order for track tables. `.added` is the playlist's own order (the "#" column).
public struct QTTrackSort: Hashable, Sendable {
    public enum Key: String, Sendable, CaseIterable { case added, title, artist, album, time }
    public var key: Key
    public var ascending: Bool

    public init(key: Key = .added, ascending: Bool = true) {
        self.key = key
        self.ascending = ascending
    }
}

/// UI state of one track list (Liked Songs, a playlist, an album…), owned by `QTNavigator`.
@MainActor
@Observable
public final class QTTrackListState {
    public var filter = ""
    public var sort = QTTrackSort()
    /// True while the big header has scrolled away and the compact bar is pinned (set by the table).
    public var isHeaderPinned = false
    @ObservationIgnored public var scrollY: CGFloat = 0
    @ObservationIgnored public var selection: [String] = []
    /// Set by the table: moves keyboard focus into the table (↓ from the filter field).
    @ObservationIgnored public var focusTable: (@MainActor () -> Void)?

    public init() {}
}

/// Filtering and sorting for track tables (pure, tested).
public enum QTTrackListing {
    public static func rows(_ tracks: [QTTrack], filter: String, sort: QTTrackSort) -> [QTTrack] {
        let q = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows = q.isEmpty ? tracks : tracks.filter { QTTextFolding.matches(query: q, in: $0.qtSearchText) }
        guard sort.key != .added else { return sort.ascending ? rows : rows.reversed() }
        let keyed: [(String, TimeInterval, QTTrack, Int)] = rows.enumerated().map { i, t in
            switch sort.key {
            case .title: (QTTextFolding.sortKey(t.title), 0, t, i)
            case .artist: (QTTextFolding.sortKey(t.artists.first?.name ?? ""), 0, t, i)
            case .album: (QTTextFolding.sortKey(t.album?.title ?? ""), 0, t, i)
            case .time: ("", t.duration, t, i)
            case .added: ("", 0, t, i)
            }
        }
        rows = keyed.sorted { a, b in
            let order: ComparisonResult = sort.key == .time
                ? (a.1 == b.1 ? .orderedSame : a.1 < b.1 ? .orderedAscending : .orderedDescending)
                : a.0.compare(b.0, options: [.numeric])
            if order == .orderedSame { return a.3 < b.3 } // stable
            return sort.ascending ? order == .orderedAscending : order == .orderedDescending
        }.map(\.2)
        return rows
    }
}
