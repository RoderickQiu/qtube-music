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
//           · window:close|reopen — close the main window / bring it back the way a Dock click does (without
//             activating the app), to check that reopening never disturbs playback
//           · remote:play|pause|toggle|next|previous — through MPRemoteCommandCenter's own dispatch
//             (QTNowPlayingController.debugSimulateSystemCommand), the path media keys and Control Center take.
//           · stage-video: pip (⇧⌘P) · eval:<function body> (page diagnostics; result lands in the command log)
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
    private var pageAccount: [String: Any]?
    private var log: [[String: Any]] = []

    func install(model: QTAppModel, setup: QTPlaybackSetup) {
        self.model = model
        self.setup = setup
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.notificationName, object: bundleID, queue: .main
        ) { note in
            let command = note.userInfo?["command"] as? String ?? ""
            QTMainActorHop.onMainThread { QTPlaybackDebugHooks.shared.perform(command) }
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
        case "pip": QTVideoModeService.shared.togglePictureInPicture()   // stage-video: ⇧⌘P
        case "eval":   // stage-video: page diagnostics (function body; result lands in the command log)
            if let web = player.engine as? QTWebPlaybackEngine {
                Task { @MainActor in
                    let result = await web.debugEvaluate(arg)
                    self.log.append(["at": ProcessInfo.processInfo.systemUptime, "command": "eval-result", "result": "\(result ?? "nil")"])
                }
            } else { ok = false }
        case "window":
            switch arg {
            case "close": NSApp.windows.first { $0.identifier == QTWindowID.main.identifier }?.close()
            case "reopen": QTDesktopCoordinator.shared.showMainWindow(activate: false)
            default: ok = false
            }
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
                    if let account = await web.debugPageAccount() { self.pageAccount = account }
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
            "mainWindowVisible": NSApp.windows.contains { $0.identifier == QTWindowID.main.identifier && $0.isVisible },
            "launchPlaybackApplied": model.didApplyLaunchPlayback,
            "catalogMode": model.liveCatalog?.mode.rawValue ?? "",
            "signedIn": model.authController?.isSignedIn ?? false,
            "anonymousPlayback": setup?.isAnonymous ?? true,
        ]
        if let pageAccount { status["page"] = pageAccount }
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
            // web-audio: the visualizer's spectrum tap (pulled only while a visualizer shows).
            status["audio"] = ["status": web.audio.status.rawValue, "active": web.audio.isActive,
                               "frames": web.audio.framesReceived, "pulls": web.audio.pulls] as [String: Any]
            // stage-video (M5): the video surface and every measured Song⇄Video switch.
            status["video"] = [
                "presenting": web.video.isPresenting, "hasFrame": web.video.hasFrame, "pip": web.video.isPictureInPictureActive,
                "width": web.video.videoSize.width, "height": web.video.videoSize.height,
                "container": web.video.container.map { String(describing: type(of: $0)) } ?? "",
            ] as [String: Any]
            status["modeSwitches"] = QTVideoModeService.lastReports.map {
                ["videoID": $0.videoID, "from": $0.from.rawValue, "to": $0.to.rawValue, "requested": $0.requested,
                 "landed": $0.landed, "offset": $0.offset, "latency": $0.latency] as [String: Any]
            }
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
