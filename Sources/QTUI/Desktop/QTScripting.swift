import AppKit
import Foundation
import QTCore

// Owner: builder "desktop". AppleScript (spec §8): Cocoa Scripting over the terminology in
// `Sources/QTubeMusicApp/Resources/QTubeMusic.sdef` (`NSAppleScriptEnabled`, `OSAScriptingDefinition` in the
// bundle's Info.plist, written by Scripts/build-app.sh).
//
//   tell application "QTube Music"
//       play / pause / playpause / next track / previous track
//       get player state            -- stopped | playing | paused
//       get name of current track   -- also artist, album, duration (s), video id
//       get player position         -- seconds; settable
//       set sound volume to 40      -- 0…100
//   end tell
//
// The AppleScript terminology only reads and controls playback. "Like Current Song" (Shortcuts / Siri,
// `likeCurrentTrack`) goes through the app's own like path, so with Sync on (the default) it likes in the YouTube
// Music account, as Controls › Like does.

public enum QTScripting {
    /// Application properties the app delegate answers (`application(_:delegateHandlesKey:)`).
    public static let applicationKeys: Set<String> = ["playerState", "currentTrack", "playerPosition", "soundVolume"]

    public static func handles(_ key: String) -> Bool { applicationKeys.contains(key) }

    /// Four-character codes of the `player state` enumeration (must match the sdef).
    public enum PlayerState: String {
        case stopped = "QTsS"
        case playing = "QTsP"
        case paused = "QTsp"

        public var code: FourCharCode { QTScripting.fourCharCode(rawValue) }
    }

    public static func fourCharCode(_ s: String) -> FourCharCode {
        s.utf8.prefix(4).reduce(0) { ($0 << 8) | FourCharCode($1) }
    }

    @MainActor static var player: QTPlayerModel { QTAppModel.shared.player }

    @MainActor public static func playerState(_ player: QTPlayerModel = QTAppModel.shared.player) -> PlayerState {
        guard player.nowPlaying != nil else { return .stopped }
        return player.isPlaying ? .playing : .paused
    }

    @MainActor public static var playerStateValue: NSNumber { NSNumber(value: playerState().code) }

    @MainActor public static var currentTrack: QTScriptTrack? { player.nowPlaying.map(QTScriptTrack.init) }

    @MainActor public static var playerPosition: Double {
        get { player.nowPlaying == nil ? 0 : player.timeline.currentTime }
        set {
            guard player.nowPlaying != nil, player.ad == nil else { return }
            player.seek(to: max(0, min(newValue, player.duration)))
        }
    }

    /// 0…100 like Music's `sound volume`.
    @MainActor public static var soundVolume: Int {
        get { Int((player.state.volume * 100).rounded()) }
        set { player.setVolume(Double(max(0, min(100, newValue))) / 100) }
    }

    @MainActor public static func perform(_ command: Command) {
        let player = player
        switch command {
        case .play:
            if !player.isPlaying, player.nowPlaying != nil { player.togglePlayPause() }
        case .pause:
            if player.isPlaying { player.togglePlayPause() }
        case .playPause:
            if player.nowPlaying != nil { player.togglePlayPause() }
        case .next:
            if player.ad?.canSkip == true { player.skipAd() } else if player.ad == nil { Task { await player.next() } }
        case .previous:
            if player.ad == nil { Task { await player.previous() } }
        }
    }

    public enum Command: Sendable { case play, pause, playPause, next, previous }

    // MARK: Shortcuts (App Intents in the app target)

    /// The current track as "Title — Artist" (nil when nothing is loaded; "Advertisement" during an ad).
    @MainActor public static var currentTrackSummary: String? {
        guard let track = player.nowPlaying else { return nil }
        if player.ad != nil { return QTLoc.tr("Advertisement") }
        return [track.title, track.artistLine].filter { !$0.isEmpty }.joined(separator: " — ")
    }

    /// What "Like Current Song" did.
    public enum LikeResult: Equatable, Sendable {
        /// Liked now, or already was (the title).
        case liked(String)
        case nothingPlaying
        /// Nothing changed: guest mode (no account to like for; the app shows its sign-in toast).
        case signInRequired
    }

    /// Likes the current track the way Controls › Like does: in the YouTube Music account when Sync is on, else on
    /// this Mac.
    @MainActor public static func likeCurrentTrack() -> LikeResult {
        guard let track = player.nowPlaying, player.ad == nil else { return .nothingPlaying }
        if !player.isLiked(track) { player.toggleLike(track) }
        return player.isLiked(track) ? .liked(track.title) : .signInRequired
    }

    /// Liked Songs + the library's playlists, as (id, title) for the Shortcuts playlist picker.
    @MainActor public static var playlists: [(id: String, title: String)] {
        let catalog = QTAppModel.shared.catalog
        return [("LM", QTLoc.tr("Liked Songs"))] + catalog.playlists.map { ($0.id, $0.title.resolved) }
    }

    @MainActor public static func playPlaylist(id: String, shuffled: Bool) -> Bool {
        let catalog = QTAppModel.shared.catalog
        let item: QTSidebarItem = id == "LM" ? .liked : .playlist(id)
        let playlist = catalog.playlists.first { $0.id == id }
        guard id == "LM" || playlist != nil,
              let target = QTSidebarPlaylistTarget(item: item, playlist: playlist) else { return false }
        target.play(shuffled: shuffled)
        return true
    }
}

/// `track` class of the scripting dictionary: a snapshot of the current track.
@objc(QTScriptTrack)
public final class QTScriptTrack: NSObject {
    @objc public let name: String
    @objc public let artist: String
    @objc public let album: String
    @objc public let duration: Double
    @objc public let videoID: String

    init(_ track: QTTrack) {
        name = track.title
        artist = track.artistLine
        album = track.album?.title ?? ""
        duration = track.duration
        videoID = track.videoId
    }

    /// `current track of application "QTube Music"`.
    public override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let app = NSScriptClassDescription(for: NSApplication.self) else { return nil }
        return NSPropertySpecifier(containerClassDescription: app, containerSpecifier: nil, key: "currentTrack")
    }
}

// MARK: Commands (class names are referenced by the sdef)

@objc(QTScriptPlayCommand)
final class QTScriptPlayCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        QTMainActorHop.onMainThread { QTScripting.perform(.play) }
        return nil
    }
}

@objc(QTScriptPauseCommand)
final class QTScriptPauseCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        QTMainActorHop.onMainThread { QTScripting.perform(.pause) }
        return nil
    }
}

@objc(QTScriptPlayPauseCommand)
final class QTScriptPlayPauseCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        QTMainActorHop.onMainThread { QTScripting.perform(.playPause) }
        return nil
    }
}

@objc(QTScriptNextTrackCommand)
final class QTScriptNextTrackCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        QTMainActorHop.onMainThread { QTScripting.perform(.next) }
        return nil
    }
}

@objc(QTScriptPreviousTrackCommand)
final class QTScriptPreviousTrackCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        QTMainActorHop.onMainThread { QTScripting.perform(.previous) }
        return nil
    }
}

#if DEBUG
/// DEBUG `-qt.desktop.scriptProbe <path>`: runs AppleScript against this app from inside it (Apple Events to the
/// own process need no Automation permission, so no system prompt) and writes the results as JSON.
@MainActor
enum QTScriptingProbe {
    static func run(writingTo path: String) async {
        let id = Bundle.main.bundleIdentifier ?? ""
        let scripts: [(String, String)] = [
            ("state", "tell application id \"\(id)\" to get player state as text"),
            ("name", "tell application id \"\(id)\" to get name of current track"),
            ("artist", "tell application id \"\(id)\" to get artist of current track"),
            ("duration", "tell application id \"\(id)\" to get duration of current track"),
            ("volume", "tell application id \"\(id)\" to get sound volume"),
            ("playpause", "tell application id \"\(id)\" to playpause"),
            ("stateAfterPlaypause", "tell application id \"\(id)\" to get player state as text"),
            ("pause", "tell application id \"\(id)\" to pause"),
            ("stateAfterPause", "tell application id \"\(id)\" to get player state as text"),
        ]
        var results: [String: String] = [:]
        for (key, source) in scripts {
            var error: NSDictionary?
            let output = NSAppleScript(source: source)?.executeAndReturnError(&error)
            try? await Task.sleep(for: .milliseconds(400)) // let the engine publish the new state
            if let error {
                results[key] = "error \(error[NSAppleScript.errorNumber] ?? "?"): \(error[NSAppleScript.errorMessage] ?? "")"
            } else {
                results[key] = output?.stringValue ?? output.map { "\($0)" } ?? "nil"
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
#endif
