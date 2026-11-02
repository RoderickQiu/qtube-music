import AppKit
import QTCore
import QTInnerTube
import QTPlayback
import SwiftUI

// "Don't Play This Artist" (docs/architecture.md › Keep AI music out). The list lives in `QTSettings.blockedArtists`
// (this Mac only). Autoplay, radio, mixes and shuffle pass blocked artists over (`QTQueueController.autoPickSkips`);
// Home, Explore, mood pages, related rows and search hide them; what the listener picks still plays, and their rows
// in playlists and the library show dimmed (`QTTrackTable`).

extension QTAppModel {
    /// The blocked artists as a matcher. Reading it inside a view body follows the setting.
    public var artistBlocklist: QTArtistBlocklist { QTArtistBlocking.blocklist(settings) }
}

@MainActor
public enum QTArtistBlocking {
    /// Session-only list for screenshots: `-qt.blockedArtists "Name,Name"` (DEBUG; never saved).
    public static let launchKey = "qt.blockedArtists"
    /// DEBUG `-qt.blockedArtists.editor YES`: Settings › Playback opens with the Blocked Artists sheet.
    public static let editorLaunchKey = "qt.blockedArtists.editor"

    private static var cache: (entries: [QTBlockedArtist], list: QTArtistBlocklist) = ([], QTArtistBlocklist())
    /// A launch list is in effect: changes stay in this session too (never written over the saved list).
    private static var isSessionOnly = false

    /// The matcher for the store's list, rebuilt only when the list changes (the queue asks per song).
    static func blocklist(_ store: QTSettingsStore) -> QTArtistBlocklist {
        let entries = store.settings.blockedArtists
        if entries != cache.entries { cache = (entries, QTArtistBlocklist(entries)) }
        return cache.list
    }

    /// The launch list (`-qt.blockedArtists`), DEBUG builds only.
    static func launchEntries(_ launch: QTLaunchOptions) -> [QTBlockedArtist]? {
        #if DEBUG
        guard let raw = launch.string(launchKey) else { return nil }
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .enumerated().map { QTBlockedArtist(name: $0.element, dateAdded: date.addingTimeInterval(Double($0.offset) * 86_400)) }
        #else
        return nil
        #endif
    }

    /// Autoplay, radio, mixes and shuffle pass blocked artists over.
    static func install(model: QTAppModel) {
        let settings = model.settings
        isSessionOnly = launchEntries(model.launch) != nil
        model.player.playback.autoPickSkips = { [weak settings] track in
            guard let settings else { return false }
            return blocklist(settings).blocks(track)
        }
    }

    // MARK: Blocking

    public static func isBlocked(_ ref: QTArtistRef, model: QTAppModel = .shared) -> Bool {
        model.artistBlocklist.blocks(ref)
    }

    /// Blocks or allows one artist, with a toast and Undo. The queue follows at once: Autoplay drops the artist's
    /// songs, and one it picked that is playing moves on.
    public static func setBlocked(_ blocked: Bool, _ ref: QTArtistRef, model: QTAppModel = .shared) {
        var list = model.artistBlocklist
        if blocked {
            let entry = QTBlockedArtist(ref)
            guard list.add(entry) else { return }
            apply(list, model: model)
            model.showToast(QTLoc.tr("Won’t play “%@”", table: .main, ref.name)) {
                var back = model.artistBlocklist
                back.remove(QTArtistRef(id: entry.channelID, name: entry.name))
                apply(back, model: model)
            }
        } else {
            let removed = list.remove(ref)
            guard !removed.isEmpty else { return }
            apply(list, model: model)
            model.showToast(QTLoc.tr("Will play “%@” again", table: .main, ref.name)) {
                var back = model.artistBlocklist
                for e in removed { back.add(e) }
                apply(back, model: model)
            }
        }
    }

    /// Settings › Blocked Artists: removes entries, no toast (the list shows it).
    static func remove(_ ids: Set<String>, model: QTAppModel = .shared) {
        let kept = model.settings.settings.blockedArtists.filter { !ids.contains($0.id) }
        apply(QTArtistBlocklist(kept), model: model)
    }

    private static func apply(_ list: QTArtistBlocklist, model: QTAppModel) {
        if isSessionOnly {
            model.settings.override { $0.blockedArtists = list.entries }
        } else {
            model.settings.update { $0.blockedArtists = list.entries }
        }
        model.player.playback.autoPickRulesDidChange()
    }

    /// The artists a song's menu offers: its credited artists, once each by name. None for an upload (they're the
    /// listener's own files).
    static func artists(of track: QTTrack) -> [QTArtistRef] {
        guard !track.isPrivatelyOwned else { return [] }
        var seen = Set<String>()
        return track.artists.filter { !$0.name.isEmpty && seen.insert(QTArtistBlocklist.nameKey($0.name)).inserted }
    }

    // MARK: Menus

    static var menuTitle: String { QTLoc.tr("Don’t Play This Artist", table: .main) }

    /// NSMenu item for a song: checked while its artist is blocked; with several artists, a submenu of their names.
    static func menuItem(for tracks: [QTTrack], model: QTAppModel = .shared) -> NSMenuItem? {
        guard tracks.count == 1, let track = tracks.first else { return nil }
        let artists = artists(of: track)
        if artists.count == 1, let artist = artists.first { return menuItem(for: artist, model: model) }
        guard !artists.isEmpty else { return nil }
        let item = NSMenuItem(title: menuTitle, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for artist in artists {
            let blocked = isBlocked(artist, model: model)
            submenu.addItem(QTClosureMenuItem(artist.name, state: blocked) { setBlocked(!blocked, artist, model: model) })
        }
        item.submenu = submenu
        item.state = artists.contains { isBlocked($0, model: model) } ? .mixed : .off
        return item
    }

    /// NSMenu item for one artist (a song by one artist, an artist page, an artist card).
    static func menuItem(for artist: QTArtistRef, model: QTAppModel = .shared) -> NSMenuItem {
        let blocked = isBlocked(artist, model: model)
        let item = QTClosureMenuItem(menuTitle, state: blocked) { setBlocked(!blocked, artist, model: model) }
        item.setAccessibilityIdentifier("qt.block.artist")
        return item
    }
}

/// The SwiftUI menu entry (context menus, Controls): a checkmark toggle for one artist; a submenu of names for a
/// song with several.
struct QTArtistBlockMenuContent: View {
    let artists: [QTArtistRef]
    /// Not from the environment: the Controls menu (Commands) has none.
    var model: QTAppModel = .shared

    init(track: QTTrack?, model: QTAppModel = .shared) {
        artists = track.map(QTArtistBlocking.artists(of:)) ?? []
        self.model = model
    }

    init(artist: QTArtistRef, model: QTAppModel = .shared) {
        artists = [artist]
        self.model = model
    }

    var body: some View {
        if artists.count == 1, let artist = artists.first {
            toggle(QTArtistBlocking.menuTitle, artist)
        } else if !artists.isEmpty {
            Menu(QTArtistBlocking.menuTitle) {
                ForEach(artists, id: \.self) { toggle($0.name, $0) }
            }
        }
    }

    private func toggle(_ title: String, _ artist: QTArtistRef) -> some View {
        let blocklist = model.artistBlocklist
        return Toggle(title, isOn: Binding(get: { blocklist.blocks(artist) },
                                           set: { QTArtistBlocking.setBlocked($0, artist, model: model) }))
    }
}

extension QTSearchResults {
    /// Without blocked artists' songs, videos, albums and artist cards — unless the search names one of them (the
    /// listener typed their name: they asked for them).
    func filtered(by blocklist: QTArtistBlocklist, query: String) -> QTSearchResults {
        let list = blocklist.ignoringArtists(named: query)
        guard !list.isEmpty else { return self }
        var r = self
        if let top = topResult, list.blocks(top) { r.topResult = nil }
        r.items = list.filter(items)
        return r
    }
}
