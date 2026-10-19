import Foundation
import QTCore

// Owner: builder "player". Session-only launch arguments for the player area (screenshots, manual testing).
//
//   -qt.player.upNext demo | <id,id,…>   seed Up Next ("demo" = the prototype's two "you added" songs)
//   -qt.player.autoplay NO               turn Autoplay off
//   -qt.player.shuffle YES               shuffle on
//   -qt.player.repeat all|one|off        repeat mode

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
    }
}
