import AppKit
import QTCore
import SwiftUI

// Right-click menu of a song card (Home's cards and quick picks, search's top result): an NSMenu with the track
// tables' items, so Add to Playlist is the shared `QTAddToPlaylistMenu` (New Playlist…, then the playlists, checked
// when they hold the song, refined from YouTube while the menu is open) — not a SwiftUI menu of toggles.

extension View {
    /// The song's context menu on right-click / Control-click; every other click passes through to the card.
    func qtTrackContextMenu(_ track: QTTrack?) -> some View {
        overlay(QTTrackContextMenuArea(track: track))
    }
}

@MainActor
enum QTTrackCardMenu {
    static func make(for track: QTTrack, model: QTAppModel = .shared) -> NSMenu {
        let menu = NSMenu()
        let playable = track.availability.isPlayable
        func add(_ title: String, enabled: Bool = true, _ action: @escaping @MainActor () -> Void) {
            menu.addItem(QTClosureMenuItem(title, enabled: enabled, handler: action))
        }
        add(QTLoc.tr("Play"), enabled: playable) { QTTrackActions.play([track], at: 0, source: nil) }
        add(QTLoc.tr("Play Next"), enabled: playable) { QTTrackActions.playNext([track]) }
        add(QTLoc.tr("Add to Queue"), enabled: playable) { QTTrackActions.addToQueue([track]) }
        menu.addItem(.separator())
        if track.hasVideo {
            add(QTLoc.tr("Play Music Video"), enabled: playable) { QTTrackActions.play([track], at: 0, source: nil, video: true) }
        } else {
            add(QTLoc.tr("No Music Video"), enabled: false) {}
        }
        if let album = track.album {
            add(QTLoc.tr("Go to Album · %@", album.title)) { QTNavigator.shared.go(.album(album)) }
        }
        if let artist = track.artists.first {
            add(QTLoc.tr("Go to Artist · %@", artist.name)) { QTNavigator.shared.go(.artist(artist)) }
        }
        menu.addItem(.separator())
        if QTLiveCatalogStore.shared.isGuest {
            // Guest mode: no playlists of one's own; the item offers to sign in.
            add(QTLoc.tr("Add to Playlist"), enabled: playable) { _ = QTAccountGate.allows(.addToPlaylist) }
        } else {
            let item = NSMenuItem(title: QTLoc.tr("Add to Playlist"), action: nil, keyEquivalent: "")
            if playable { item.submenu = QTAddToPlaylistMenu.make(for: [track]) }
            menu.addItem(item)
        }
        add(QTLoc.tr(model.player.isLiked(track) ? "Remove from Liked Songs" : "Like")) { QTTrackActions.toggleLike([track]) }
        menu.addItem(.separator())
        // An upload has no link to share.
        add(QTLoc.tr("Copy Link"), enabled: QTTrackActions.canCopyLinks([track])) { QTTrackActions.copyLinks([track]) }
        return menu
    }
}

/// A transparent view over the card that only takes menu clicks.
private struct QTTrackContextMenuArea: NSViewRepresentable {
    let track: QTTrack?

    func makeNSView(context: Context) -> MenuView {
        let v = MenuView()
        v.track = track
        v.setAccessibilityElement(false)
        return v
    }

    func updateNSView(_ nsView: MenuView, context: Context) { nsView.track = track }

    final class MenuView: NSView {
        var track: QTTrack?

        /// Only right-clicks and Control-clicks land here; hovering, clicks, double-clicks and drags reach the card.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard track != nil, let event = NSApp.currentEvent else { return nil }
            let isMenuClick = event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return isMenuClick ? super.hitTest(point) : nil
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            track.map { QTTrackCardMenu.make(for: $0) }
        }

        override func rightMouseDown(with event: NSEvent) {
            guard let menu = menu(for: event) else { return super.rightMouseDown(with: event) }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }

        override func mouseDown(with event: NSEvent) {
            guard event.modifierFlags.contains(.control), let menu = menu(for: event) else {
                return super.mouseDown(with: event)
            }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
}
