#if DEBUG
import AppKit
import Foundation
import MediaPlayer
import QTCore
import QTPlayback

// Owner: builder "playback". DEBUG-only remote control for scripts (Scripts/playback-acceptance.py): no synthetic
// input, no focus changes. Commands arrive as distributed notifications addressed to this bundle id; state goes
// out as a JSON file.
//
//   name   com.roderickqiu.qtube.debug.playback
//   object the target app's bundle id (variants never answer each other's commands)
//   info   {"command": "<name>[:<arg>]"}
//
// Commands: play · pause · toggle · next · previous · skipAd · seek:<s> · seekEnd:<s before end> · mode:song|video
//           · surface:window|stage · panel:now-playing|queue · offline · online
//           · remote:play|pause|toggle|next|previous — through MPRemoteCommandCenter's own dispatch
//             (QTNowPlayingController.debugSimulateSystemCommand), the path media keys and Control Center take.
// Status (`-qt.playback.statusFile <path>`, rewritten twice a second): engine state, queue position, ad, last
// failure + toast, the Now Playing info this process published, page media volume (proof of silence).

@MainActor
final class QTPlaybackDebugHooks {
    static let shared = QTPlaybackDebugHooks()
    static let notificationName = Notification.Name("com.roderickqiu.qtube.debug.playback")

    private weak var model: QTAppModel?
    private var setup: QTPlaybackSetup?
    private var observer: NSObjectProtocol?
    private var statusTask: Task<Void, Never>?
    private var mediaInfo: [String: Any]?
    private var log: [[String: Any]] = []

    func install(model: QTAppModel, setup: QTPlaybackSetup) {
        self.model = model
        self.setup = setup
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.notificationName, object: bundleID, queue: .main
        ) { note in
            let command = note.userInfo?["command"] as? String ?? ""
            MainActor.assumeIsolated { QTPlaybackDebugHooks.shared.perform(command) }
        }
        if let path = model.launch.string("qt.playback.statusFile") {
            startStatus(URL(fileURLWithPath: path))
        }
    }

    // MARK: Commands

    func perform(_ raw: String) {
        guard let model else { return }
        let player = model.player
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        let name = parts.first ?? ""
        let arg = parts.count > 1 ? parts[1] : ""
        var ok = true
        switch name {
        case "play": player.play()
        case "pause": player.pause()
        case "toggle": player.togglePlayPause()
        case "next": Task { await player.next() }
        case "previous": Task { await player.previous() }
        case "skipAd": player.skipAd()
        case "seek": player.seek(to: Double(arg) ?? 0)
        case "seekEnd": player.seek(to: max(0, player.duration - (Double(arg) ?? 4)))
        case "mode": model.isVideoMode = arg == "video"
        case "surface": model.surface = QTSurface(argument: arg) ?? .window
        case "panel":
            model.isPanelShown = true
            model.panelTab = QTPanelTab(argument: arg) ?? .nowPlaying
        case "offline", "online":
            (player.engine as? QTWebPlaybackEngine)?.networkChanged(available: name == "online")
        case "remote":
            ok = player.playback.nowPlaying?.debugSimulateSystemCommand(arg) ?? false
        default: ok = false
        }
        log.append(["at": ProcessInfo.processInfo.systemUptime, "command": raw, "ok": ok])
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    // MARK: Status file

    private func startStatus(_ url: URL) {
        statusTask = Task { @MainActor [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                let active = self.model.map { $0.player.isPlaying || $0.player.isBuffering } ?? false
                if active, tick % 4 == 0, let web = self.model?.player.engine as? QTWebPlaybackEngine {
                    self.mediaInfo = await web.debugMediaInfo()
                }
                self.writeStatus(to: url)
                tick += 1
                // Back off while paused so the harness doesn't inflate idle CPU measurements.
                try? await Task.sleep(for: .milliseconds(active ? 500 : 2000))
            }
        }
    }

    private func writeStatus(to url: URL) {
        guard let model else { return }
        let player = model.player
        let state = player.state
        let queue = player.queue
        var status: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "bundleID": Bundle.main.bundleIdentifier ?? "",
            "uptime": ProcessInfo.processInfo.systemUptime,
            "engine": setup?.engine.rawValue ?? "",
            "silent": setup?.isSilent ?? false,
            "status": Self.describe(state.status),
            "isPlaying": state.isPlaying,
            "isBuffering": player.isBuffering,
            "time": state.timeline.currentTime,
            "duration": state.duration,
            "mode": player.mode.rawValue,
            "surface": model.surface.rawValue,
            "videoID": player.nowPlaying?.videoId ?? "",
            "title": player.nowPlaying?.title ?? "",
            "historyCount": queue.history.count,
            "upNextCount": queue.upNext.count,
            "autoplayCount": queue.autoplay.count,
            "toast": model.toast?.message ?? "",
            "lastFailureMessage": QTPlaybackServices.shared.lastFailureMessage ?? "",
            "commands": log,
        ]
        if let failure = player.playback.lastFailure { status["lastFailure"] = "\(failure)" }
        if let ad = state.ad {
            status["ad"] = ["duration": ad.duration, "remaining": ad.remaining, "skippableIn": ad.skippableIn ?? -1, "canSkip": ad.canSkip]
        }
        if let web = player.engine as? QTWebPlaybackEngine {
            status["playingVideoID"] = web.playingVideoID ?? ""
            status["pageFrozen"] = web.isPageFrozen
            status["networkAvailable"] = web.isNetworkAvailable
            if let pid = web.webContentProcessIdentifier { status["webContentPID"] = Int(pid) }
            if let mediaInfo { status["media"] = mediaInfo }
        }
        if let np = player.playback.nowPlaying {
            var published: [String: Any] = ["active": np.isActive]
            if let s = np.snapshot {
                published["videoID"] = s.videoID
                published["title"] = s.title
                published["artist"] = s.artist
                published["rate"] = s.rate
                published["duration"] = s.duration
                published["isAd"] = s.isAd
            }
            let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            published["hasArtwork"] = info[MPMediaItemPropertyArtwork] != nil
            published["elapsed"] = info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? -1
            published["playbackState"] = MPNowPlayingInfoCenter.default().playbackState.rawValue
            status["nowPlaying"] = published
        }
        guard let data = try? JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func describe(_ status: QTPlaybackStatus) -> String {
        switch status {
        case .idle: "idle"
        case .loading: "loading"
        case .playing: "playing"
        case .paused: "paused"
        case .ended: "ended"
        case .failed(let e): "failed(\(e))"
        }
    }
}
#endif
