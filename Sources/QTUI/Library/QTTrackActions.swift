import AppKit
import QTCore

/// What songs can do from any list (table rows, Home cards, search, sidebar drops), with the prototype's toasts.
/// Every action that changes something offers Undo where the prototype does.
@MainActor
public enum QTTrackActions {
    /// Web link for a track (also what a dragged row carries to other apps).
    public static func link(for track: QTTrack) -> String { "https://music.youtube.com/watch?v=\(track.videoId)" }

    /// Parses a dragged/pasted link (or a bare id) back to a video id.
    public static func videoID(fromLink string: String) -> String? {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let comps = URLComponents(string: s), comps.host?.hasSuffix("youtube.com") == true,
           let v = comps.queryItems?.first(where: { $0.name == "v" })?.value, !v.isEmpty {
            return v
        }
        if s.hasPrefix(dragPrefix) { return String(s.dropFirst(dragPrefix.count)) }
        return nil
    }

    static let dragPrefix = "qtube-track:"

    /// Plays `tracks[index]` with the rest of the (playable) list continuing as Autoplay.
    public static func play(_ tracks: [QTTrack], at index: Int, source: QTQueueSource?, video: Bool = false,
                            model: QTAppModel = .shared) {
        guard tracks.indices.contains(index), tracks[index].availability.isPlayable else { return }
        let target = tracks[index]
        let playable = tracks.filter(\.availability.isPlayable)
        let start = playable.firstIndex(of: target) ?? 0
        let wantsVideo = video && target.hasVideo
        if wantsVideo { model.isVideoMode = true }
        Task { await model.player.play(playable, startingAt: start, source: source, mode: wantsVideo ? .video : .song) }
    }

    public static func shuffle(_ tracks: [QTTrack], source: QTQueueSource?, model: QTAppModel = .shared) {
        let playable = tracks.filter(\.availability.isPlayable).shuffled()
        guard !playable.isEmpty else { return }
        model.player.isShuffleOn = true
        Task { await model.player.play(playable, startingAt: 0, source: source) }
    }

    public static func playNext(_ tracks: [QTTrack], model: QTAppModel = .shared) {
        let playable = tracks.filter(\.availability.isPlayable)
        guard !playable.isEmpty else { return }
        model.player.playNext(playable)
        if playable.count == 1 {
            model.showToast(QTLoc.tr("“%@” will play next", playable[0].title))
        } else {
            model.showToast(QTLoc.tr("%lld songs will play next", table: .main, playable.count))
        }
    }

    public static func addToQueue(_ tracks: [QTTrack], model: QTAppModel = .shared) {
        let playable = tracks.filter(\.availability.isPlayable)
        guard !playable.isEmpty else { return }
        model.player.addToQueue(playable)
        model.showToast(QTLoc.tr("Added to Up Next"))
    }

    /// Likes all when any is unliked, otherwise unlikes all (with Undo). The toast says where the like went: the
    /// account (syncing) or this Mac (Settings › Account › Sync off).
    public static func toggleLike(_ tracks: [QTTrack], model: QTAppModel = .shared, writer: QTAccountWriter = .shared) {
        guard !tracks.isEmpty, QTAccountGate.allows(.like, model: model) else { return }
        let player = model.player
        let like = tracks.contains { !player.isLiked($0) }
        let changed = tracks.filter { player.isLiked($0) != like }
        for t in changed { player.setLiked(t, like) }
        let message = writer.savesToAccount
            ? QTLoc.tr(like ? "Added to Liked Songs" : "Removed from Liked Songs")
            : QTLoc.tr(like ? "Liked on this Mac" : "Removed from Liked Songs on this Mac", table: .live)
        model.showToast(message) {
            for t in changed { player.setLiked(t, !like) }
        }
    }

    public static func copyLinks(_ tracks: [QTTrack], model: QTAppModel = .shared) {
        guard !tracks.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(tracks.map(link(for:)).joined(separator: "\n"), forType: .string)
        model.showToast(QTLoc.tr("Link copied"))
    }

    /// Adds the songs not already in the playlist (`QTAccountWriter`); toast "Added “x” to y" (or "… on this Mac")
    /// with Undo.
    public static func add(_ tracks: [QTTrack], to playlist: QTPlaylist, model: QTAppModel = .shared,
                           writer: QTAccountWriter = .shared) {
        let playable = tracks.filter(\.availability.isPlayable)
        guard !playable.isEmpty, QTAccountGate.allows(.addToPlaylist, model: model) else { return }
        let name = playlist.title.resolved
        let added = writer.add(playable, to: playlist)
        guard !added.isEmpty else {
            model.showToast(QTLoc.tr("Already in %@", table: .main, name))
            return
        }
        let message: String
        switch (added.count == 1, writer.savesToAccount) {
        case (true, true): message = QTLoc.tr("Added “%@” to %@", added[0].title, name)
        case (false, true): message = QTLoc.tr("Added %lld songs to %@", table: .main, added.count, name)
        case (true, false): message = QTLoc.tr("Added “%@” to %@ on this Mac", table: .live, added[0].title, name)
        case (false, false): message = QTLoc.tr("Added %lld songs to %@ on this Mac", table: .live, added.count, name)
        }
        model.showToast(message) { writer.remove(added, from: playlist) }
    }

    /// Takes songs out of a playlist the account owns (⌫, context menu); Undo puts them back where they were.
    public static func remove(_ tracks: [QTTrack], from playlist: QTPlaylist, model: QTAppModel = .shared,
                              writer: QTAccountWriter = .shared) {
        guard !tracks.isEmpty, writer.canEdit(playlist) else { return }
        let before = writer.rows(of: playlist)
        let ids = Set(tracks.map(\.videoId))
        let removed = before.filter { ids.contains($0.videoId) }
        guard !removed.isEmpty else { return }
        writer.remove(removed, from: playlist)
        let name = playlist.title.resolved
        let message = removed.count == 1
            ? QTLoc.tr("Removed “%@” from %@", table: .live, removed[0].title, name)
            : QTLoc.tr("Removed %lld songs from %@", table: .live, removed.count, name)
        model.showToast(message) {
            // Back in, then each to its old place (first row first, so the later indexes hold).
            writer.add(removed, to: playlist)
            for (index, t) in before.enumerated() where ids.contains(t.videoId) {
                writer.move([t], in: playlist, to: index)
            }
        }
    }

    /// Resolves dragged strings (links or ids) to catalog tracks.
    public static func tracks(fromDropped strings: [String], catalog: QTMockCatalog) -> [QTTrack] {
        strings.flatMap { $0.split(separator: "\n").map(String.init) }
            .compactMap { videoID(fromLink: $0) ?? (catalog.track(id: $0) != nil ? $0 : nil) }
            .compactMap { catalog.track(id: $0) }
    }
}
