import AppKit
import Foundation
import QTCore
import SwiftUI

// Owner: builder "player". Session-only launch arguments for the player area (screenshots, manual testing).
//
//   -qt.player.upNext demo | <id,id,…>   seed Up Next ("demo" = the prototype's two "you added" songs)
//   -qt.player.autoplay NO               turn Autoplay off
//   -qt.player.shuffle YES               shuffle on
//   -qt.player.repeat all|one|off        repeat mode
//   -qt.player.adElapsed <s>             with -qt.ad YES: run the launch ad for <s> seconds, then pause (6 = skippable)
//   -qt.player.keyAppearance YES         DEBUG: draw the window as key in background captures (best effort)

@MainActor
enum QTPlayerLaunch {
    /// The prototype's default Up Next (player.jsx `upNext`).
    static let demoUpNext = ["ne1968907343", "ne460043703"]

    static func apply(_ launch: QTLaunchOptions, catalog: QTMockCatalog, to player: QTPlayerModel) {
        if let list = launch.string("qt.player.upNext") {
            let ids = list == "demo" ? demoUpNext : list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let tracks = ids.compactMap { id in catalog.tracks.first { $0.videoId == id } }
            if !tracks.isEmpty {
                // Up Next items aren't also Autoplay items (prototype behaviour).
                let removing = Set(tracks.map(\.videoId))
                player.removeFromQueue(Set(player.queue.autoplay.filter { removing.contains($0.track.videoId) }.map(\.id)))
                player.addToQueue(tracks)
            }
        }
        if let on = launch.bool("qt.player.autoplay") { player.setAutoplayEnabled(on) }
        if let on = launch.bool("qt.player.shuffle") { player.isShuffleOn = on }
        if let mode = launch.string("qt.player.repeat").flatMap(QTRepeatMode.init(rawValue:)) { player.repeatMode = mode }
        if let elapsed = launch.double("qt.player.adElapsed"), elapsed > 0 { runAd(for: elapsed, player: player) }
    }

    /// `-qt.ad YES -qt.player.adElapsed 6`: lets the (paused) launch ad run for `elapsed` seconds, then pauses it
    /// again, holding readiness meanwhile, so screenshots of "Skip in 3" / Skip are deterministic.
    private static func runAd(for elapsed: Double, player: QTPlayerModel) {
        let hold = QTReadiness.shared.hold("qt.player.adElapsed")
        Task { @MainActor in
            // `applyLaunchPlayback` starts the forced ad right after this; let it.
            try? await Task.sleep(for: .milliseconds(50))
            if player.ad != nil {
                player.play()
                try? await Task.sleep(for: .seconds(elapsed))
                player.pause()
            }
            QTReadiness.shared.release(hold)
        }
    }
}

/// DEBUG capture aid: `-qt.player.keyAppearance YES` draws the host window as if it were key (segmented
/// controls, accessory-bar toggles, traffic lights), so background screenshots show the active rendering without
/// taking focus. Uses AppKit's private force-active hooks and is compiled out of release builds.
struct QTPlayerKeyAppearanceProbe: View {
    @Environment(QTAppModel.self) private var model

    var body: some View {
        #if DEBUG
        if model.launch.bool("qt.player.keyAppearance") == true {
            QTWindowAccessor { window in
                // Best effort: AppKit sometimes keeps the inactive rendering (e.g. while Stage Manager re-places
                // the window), so re-assert it a few times and give it a moment before Scripts/shoot.sh captures.
                // Check the capture (accent-filled segmented control / Play button) and retake if needed.
                let hold = QTReadiness.shared.hold("qt.player.keyAppearance")
                Task { @MainActor [weak window] in
                    for step in 0..<12 {
                        if let window { Self.force(window) }
                        if step == 3 { QTReadiness.shared.release(hold) }
                        try? await Task.sleep(for: .milliseconds(400))
                    }
                    QTReadiness.shared.release(hold)
                }
            }
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        #endif
    }

    #if DEBUG
    @MainActor
    private static func force(_ window: NSWindow) {
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        for name in ["_setForceActiveControls:", "_setForceMainAppearance:"] {
            let selector = NSSelectorFromString(name)
            guard let method = class_getInstanceMethod(type(of: window), selector) else { continue }
            let set = unsafeBitCast(method_getImplementation(method), to: Setter.self)
            set(window, selector, true)
        }
        func invalidate(_ view: NSView) {
            view.needsDisplay = true
            view.subviews.forEach(invalidate)
        }
        window.contentView.map(invalidate)
    }
    #endif
}
