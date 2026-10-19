import AppKit
import QTCore

// Owner: builder "desktop". The Dock menu: what's playing, transport, like, shuffle/repeat, mini player and
// desktop lyrics. Built fresh each time it opens, so titles follow the interface language and current state.

@MainActor
enum QTDockMenuBuilder {
    static func menu(model: QTAppModel?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard let model else { return menu }
        let player = model.player
        if let track = player.nowPlaying {
            let header = NSMenuItem(title: player.ad != nil ? QTLoc.tr("Advertisement") : track.title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            if player.ad == nil {
                let artist = NSMenuItem(title: track.artistLine, action: nil, keyEquivalent: "")
                artist.isEnabled = false
                artist.indentationLevel = 0
                menu.addItem(artist)
            }
            menu.addItem(.separator())
        }
        menu.addItem(QTClosureMenuItem(QTLoc.tr(player.isPlaying ? "Pause" : "Play")) { player.togglePlayPause() })
        menu.addItem(QTClosureMenuItem(QTLoc.tr("Next"), enabled: player.ad.map(\.canSkip) ?? true) {
            if player.ad != nil { player.skipAd() } else { Task { await player.next() } }
        })
        menu.addItem(QTClosureMenuItem(QTLoc.tr("Previous"), enabled: player.ad == nil) { Task { await player.previous() } })
        if let track = player.nowPlaying {
            menu.addItem(.separator())
            menu.addItem(QTClosureMenuItem(QTLoc.tr(player.isLiked(track) ? "Remove from Liked Songs" : "Like")) { player.toggleLike(track) })
        }
        menu.addItem(.separator())
        menu.addItem(QTClosureMenuItem(QTLoc.tr("Shuffle"), state: player.isShuffleOn) { player.isShuffleOn.toggle() })
        menu.addItem(QTClosureMenuItem(QTLoc.tr("Repeat"), state: player.repeatMode != .off) {
            player.repeatMode = player.repeatMode == .off ? .all : .off
        })
        menu.addItem(.separator())
        menu.addItem(QTClosureMenuItem(QTLoc.tr("Mini Player"), state: model.surface == .mini) {
            QTDesktopCoordinator.shared.toggleMiniPlayer()
        })
        menu.addItem(QTClosureMenuItem(QTLoc.tr("Desktop Lyrics"), state: model.isDesktopLyricsShown) {
            QTDesktopCoordinator.shared.toggleDesktopLyrics()
        })
        return menu
    }
}

/// NSMenuItem with a closure action (Dock menu, AppKit-built menus).
@MainActor
final class QTClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, enabled: Bool = true, state: Bool? = nil, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        isEnabled = enabled
        if let state { self.state = state ? .on : .off }
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }

    @objc private func fire() {
        handler()
    }
}
