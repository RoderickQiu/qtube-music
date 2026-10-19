import AppKit
import QTCore

/// Space = play/pause anywhere in the main window, except while typing or when a focused control uses Space
/// (a bare-Space menu key equivalent would fire inside search fields, so it's handled here instead).
@MainActor
final class QTWindowKeyMonitor {
    static let shared = QTWindowKeyMonitor()
    private var monitor: Any?

    func install(model: QTAppModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 49,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .function, .numericPad]).isEmpty
            else { return event }
            let windowNumber = event.windowNumber
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let window = NSApp.window(withWindowNumber: windowNumber), window.identifier == QTWindowID.main.identifier,
                      !Self.responderUsesSpace(window.firstResponder) else { return false }
                model.player.togglePlayPause()
                return true
            }
            return handled ? nil : event
        }
    }

    private static func responderUsesSpace(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        if responder is NSText || responder is NSTextView { return true }
        if let view = responder as? NSView {
            // Full Keyboard Access: Space presses the focused control.
            if view is NSButton || view is NSSegmentedControl || view is NSPopUpButton || view is NSSlider { return true }
            if view is NSTextField, (view as? NSTextField)?.isEditable == true { return true }
        }
        return false
    }
}

/// Launch arguments of the "window" area (session-only, for screenshots and tests):
///
/// | Key | Value | Effect |
/// |---|---|---|
/// | `qt.window.search` | text | toolbar search text (shows search results) |
/// | `qt.library.filter` | text | filter of the opening track list |
/// | `qt.library.scroll` | points | scroll offset of the opening track list (≥ 160 pins the compact header) |
/// | `qt.library.sort` | `title` `album` `artist` `time` `added`, `:desc` suffix | sort of the opening list |
/// | `qt.library.select` | row numbers, comma separated (1-based) | selected rows |
/// | `qt.home.scroll` | points | Home scroll offset |
/// | `qt.window.page` | `album:<title>` `artist:<name>` `mood:<id>` | opens a page on top of `qt.section` |
/// | `qt.window.scroll` | points | scroll offset of the opening browse page (Explore, artist, mood) |
@MainActor
enum QTWindowLaunchHooks {
    static func apply(_ launch: QTLaunchOptions, model: QTAppModel, navigator: QTNavigator) {
        if let page = launch.string("qt.window.page"), let d = destination(page, model: model) { navigator.go(d) }
        if let y = launch.double("qt.window.scroll") { navigator.setScrollOffset(y, for: navigator.current) }
        if let q = launch.string("qt.window.search") { model.searchText = q }
        guard let key = QTTrackCollection.listKey(for: navigator.current) else { return }
        let state = navigator.listState(for: key)
        if let f = launch.string("qt.library.filter") { state.filter = f }
        if let y = launch.double("qt.library.scroll") { state.scrollY = y }
        if let s = launch.string("qt.library.sort") {
            let parts = s.split(separator: ":")
            if let k = parts.first.flatMap({ QTTrackSort.Key(rawValue: String($0)) }) {
                state.sort = QTTrackSort(key: k, ascending: parts.dropFirst().first != "desc")
            }
        }
        if let sel = launch.string("qt.library.select") {
            let tracks = collectionTracks(for: navigator.current, model: model)
            let rows = QTTrackListing.rows(tracks, filter: state.filter, sort: state.sort)
            state.selection = sel.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                .compactMap { rows.indices.contains($0 - 1) ? rows[$0 - 1].videoId : nil }
            model.selectedTrackIDs = Set(state.selection)
        }
    }

    /// `album:<title>`, `artist:<name>`, `mood:<id>` (Home moods and Explore genres).
    static func destination(_ s: String, model: QTAppModel) -> QTDestination? {
        guard let colon = s.firstIndex(of: ":") else { return nil }
        let kind = s[..<colon], value = String(s[s.index(after: colon)...])
        switch kind {
        case "album": return .album(value)
        case "artist": return .artist(value)
        case "mood":
            // Demo moods/genres by id; any other id is a YouTube Music mood browse id (live library).
            let moods = QTMockBrowseService(catalog: model.catalog).moodsNow().groups.flatMap(\.moods) + model.catalog.home.moods
            return .mood(moods.first { $0.id == value } ?? QTMoodChip(id: value, title: .verbatim(value)))
        default: return nil
        }
    }

    static func collectionTracks(for d: QTDestination, model: QTAppModel) -> [QTTrack] {
        let c = model.catalog
        switch d {
        case .section(.liked): return QTTrackCollection.liked(c).tracks
        case .section(.songs): return c.tracks
        case .section(.playlist(let id)): return c.playlists.first { $0.id == id }.map { QTTrackCollection.playlist($0, catalog: c).tracks } ?? []
        case .album(let t): return QTTrackCollection.album(t, catalog: c).tracks
        case .artist(let n): return QTTrackCollection.artist(n, catalog: c).tracks
        default: return []
        }
    }
}

extension QTWindowPlacement {
    /// Whether the app places the main window on this launch: for explicit dev/screenshot placement
    /// (`-qt.screen`, `-qt.window`), and on a first launch (no autosaved frame yet). Otherwise the frame AppKit
    /// restored — the user's own size and position — stays (draft §8).
    static func shouldPlaceMainWindow(_ window: NSWindow, launch: QTLaunchOptions, defaults: UserDefaults = .standard) -> Bool {
        if launch.screen != nil || launch.windowSize != nil { return true }
        return !hasAutosavedFrame(window, defaults: defaults)
    }

    static func hasAutosavedFrame(_ window: NSWindow?, defaults: UserDefaults = .standard) -> Bool {
        let names = Set([window?.frameAutosaveName ?? "", QTWindowID.main.rawValue].filter { !$0.isEmpty })
        return names.contains { defaults.string(forKey: "NSWindow Frame \($0)") != nil }
    }
}
