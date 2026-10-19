import AppKit
import Foundation
import QTCore
import WebKit

// Owner: builder "video-polish". Seamless Song⇄Video: the other rendition of the playing track is prepared in a
// second, silent player page and crossfaded in at the same moment, so the music never stops.
//
// How a switch runs (only while content plays; paused, ads, near the end, offline → the in-page reload):
// 1. The engine's state takes the new item at once (Song | Video, the slots' placeholder) and keeps the old page's
//    clock: nothing looks like loading.
// 2. A standby page loads the counterpart a few seconds ahead of the current position, muted, at the slot's quality
//    when it will show the video. As soon as it plays it is paused there (it has buffered).
// 3. When the old page's clock reaches the standby's position the standby plays, and the two crossfade (equal
//    power, `crossfade`). If the standby fell behind it seeks further ahead first.
// 4. The standby becomes the engine's page (a slot showing the video takes it); the old page is closed.
// Anything unusual (an ad on the standby, an error, a slow load, the listener pausing or seeking) drops the standby
// and falls back to the in-page reload at the then-current position — the old behaviour, a short gap.

/// One seamless switch in flight.
@MainActor
final class QTWebStandbySwitch {
    enum Outcome { case done, superseded, fallBack }

    let item: QTPlaybackItem
    let videoID: String
    let generation: Int
    let proxy: QTWebPlaybackMessageProxy
    var webView: WKWebView?
    var window: NSWindow?
    var isReady = false
    var lastSample: QTWebPlaybackSample?
    var failed = false
    /// Set when something ended the switch from outside (`cancelStandby`).
    var cancelled: Outcome?

    init(item: QTPlaybackItem, videoID: String, generation: Int, proxy: QTWebPlaybackMessageProxy) {
        self.item = item
        self.videoID = videoID
        self.generation = generation
        self.proxy = proxy
    }

    func receive(_ body: Any) {
        guard let dict = body as? [String: Any], let type = dict["type"] as? String else { return }
        switch type {
        case "ready": isReady = true
        case "state":
            guard let sample = QTWebPlaybackSample(dict), sample.generation == generation else { return }
            lastSample = sample
        case "error", "ended": failed = true
        default: break
        }
    }

    /// Calls `window.__qtBridge.<name>(…)` on the standby page.
    func call(_ name: String, _ args: Any...) async -> Any? {
        guard let webView, isReady else { return nil }
        return await QTWebStandbySwitch.call(webView, name, args)
    }

    static func call(_ webView: WKWebView, _ name: String, _ args: [Any]) async -> Any? {
        var arguments: [String: Any] = [:]
        var list: [String] = []
        for (i, a) in args.enumerated() {
            arguments["a\(i)"] = a
            list.append("a\(i)")
        }
        let js = "return window.__qtBridge ? window.__qtBridge.\(name)(\(list.joined(separator: ", "))) : null"
        return try? await webView.callAsyncJavaScript(js, arguments: arguments, in: nil, contentWorld: .page)
    }

    func tearDown() {
        proxy.role = .retired
        proxy.onStandbyMessage = nil
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView?.removeFromSuperview()
        window?.close()
        webView = nil
        window = nil
    }
}

extension QTWebPlaybackEngine {
    /// Crossfade length, seconds.
    static let modeSwitchCrossfade: TimeInterval = 0.4
    /// The standby gives up (in-page reload instead) after this long without a playable, buffered rendition.
    static let modeSwitchStandbyTimeout: TimeInterval = 12

    func canSwitchSeamlessly(autoplay: Bool) -> Bool {
        guard configuration.seamlessModeSwitch, autoplay, state.status == .playing, state.ad == nil, !state.isBuffering,
              isPageReady, !needsFreshPage, pendingLoads.isEmpty, webView != nil, isNetworkAvailable,
              configuration.debugLoadDelay == nil else { return false }
        // Near the end the next track is about to load anyway.
        let remaining = state.duration > 0 ? state.duration - state.timeline.currentTime : .infinity
        return remaining > 12
    }

    /// Drops a switch in flight (its page closes). `.fallBack` lets the waiting `load` continue in the page.
    func cancelStandby(_ outcome: QTWebStandbySwitch.Outcome) {
        guard let s = standby else { return }
        standby = nil
        s.cancelled = outcome
        s.tearDown()
    }

    /// Runs one seamless switch (see the file header). Returns how it ended.
    func seamlessModeSwitch(to item: QTPlaybackItem, videoID: String, from: QTPlaybackMode) async -> QTWebStandbySwitch.Outcome {
        guard let mainView = webView else { return .fallBack }
        let requestedAt = ProcessInfo.processInfo.systemUptime
        let startedAt = state.timeline.currentTime
        let proxy = QTWebPlaybackMessageProxy(engine: self, role: .standby)
        let s = QTWebStandbySwitch(item: item, videoID: videoID, generation: generation + 1, proxy: proxy)
        proxy.onStandbyMessage = { [weak s] body in s?.receive(body) }
        standby = s

        // 1. The switch shows at once; the clock keeps running on the old page.
        state.item = item
        video.itemDidChange(isVideo: item.mode == .video)
        publish()

        // 2. The standby page, ahead of the current position, silent.
        let lead = max(1.5, modeSwitchReadyEstimate + 0.5)
        let target = startedAt + lead
        let presents = video.isPresenting && item.mode == .video
        let bootstrap = QTWebPlaybackBridgeScript.bootstrap(generation: s.generation, videoID: videoID, hold: false,
                                                            volume: 0, muted: true, silent: configuration.isSilent,
                                                            lowQuality: configuration.prefersLowVideoQuality,
                                                            present: presents, quality: presents ? video.quality : "tiny",
                                                            standby: true)
        let (view, window) = makePage(bootstrap: bootstrap, proxy: proxy)
        s.webView = view
        s.window = window
        var components = URLComponents(url: configuration.origin.appending(path: "watch"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "v", value: videoID), URLQueryItem(name: "t", value: "\(Int(target.rounded(.up)))s")]
        view.load(URLRequest(url: components.url!))
        QTWebVideoOutput.log.info("seamless switch \(from.rawValue, privacy: .public)→\(item.mode.rawValue, privacy: .public): standby \(videoID, privacy: .public) from \(target, format: .fixed(precision: 1)) s")

        func alive() -> QTWebStandbySwitch.Outcome? {
            if let c = s.cancelled { return c }
            if standby !== s { return .superseded }
            if s.failed { return fallBack(s, "standby error") }
            if s.lastSample?.ad != nil { return fallBack(s, "standby ad") }
            return nil
        }

        // Wait until the standby plays content (it buffers), then hold it there.
        let deadline = requestedAt + Self.modeSwitchStandbyTimeout
        while true {
            if let end = alive() { return end }
            if let sample = s.lastSample, sample.matchesLoad, sample.ad == nil, !sample.paused, sample.playerState == 1,
               sample.readyState >= 3 { break }
            if ProcessInfo.processInfo.systemUptime > deadline {
                let last = s.lastSample.map { "match \($0.matchesLoad) ps \($0.playerState) paused \($0.paused) rs \($0.readyState)" } ?? "no sample"
                return fallBack(s, "standby timeout (ready \(s.isReady), \(last))")
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
        let readyAfter = ProcessInfo.processInfo.systemUptime - requestedAt
        modeSwitchReadyEstimate = modeSwitchReadyEstimate * 0.5 + readyAfter * 0.5
        _ = await s.call("pause")

        // 3. Line the standby up with the old page's clock, then play it and crossfade.
        var attempts = 0
        var standbyTime: TimeInterval = 0
        while true {
            if let end = alive() { return end }
            guard let b = await s.call("sample") as? [String: Any], let tb = b["t"] as? Double,
                  let a = await QTWebStandbySwitch.call(mainView, "sample", []) as? [String: Any], let ta = a["t"] as? Double
            else { return fallBack(s, "no clock") }
            if let end = alive() { return end }
            standbyTime = tb
            let wait = tb - ta - modeSwitchPlayLatency
            if wait >= 0.03, wait < 8 { break }
            // Fell behind (a slow load) or far ahead: seek the held standby a little ahead of the old page.
            attempts += 1
            if attempts > 2 { return fallBack(s, "could not line up") }
            _ = await s.call("seek", ta + 1.2)
            let seekDeadline = ProcessInfo.processInfo.systemUptime + 4
            while true {
                try? await Task.sleep(for: .milliseconds(60))
                if let end = alive() { return end }
                if let b = await s.call("sample") as? [String: Any], (b["rs"] as? Int ?? 0) >= 3,
                   abs((b["t"] as? Double ?? 0) - (ta + 1.2)) < 1 { break }
                if ProcessInfo.processInfo.systemUptime > seekDeadline { return fallBack(s, "seek timeout") }
            }
        }
        guard let a = await QTWebStandbySwitch.call(mainView, "sample", []) as? [String: Any], let ta = a["t"] as? Double
        else { return fallBack(s, "no clock") }
        let wait = standbyTime - ta - modeSwitchPlayLatency
        if wait > 0 { try? await Task.sleep(for: .milliseconds(Int(wait * 1000))) }
        if let end = alive() { return end }
        let playAsked = ProcessInfo.processInfo.systemUptime
        _ = await s.call("play")
        // Playing again (a buffered resume: tens of ms).
        var landed = standbyTime
        var oldTime = ta
        for _ in 0..<50 {
            if let end = alive() { return end }
            let bAny = await s.call("sample")
            let aAny = await QTWebStandbySwitch.call(mainView, "sample", [])
            if let b = bAny as? [String: Any], (b["paused"] as? Bool) == false, let tb = b["t"] as? Double, tb > standbyTime + 0.005 {
                landed = tb
                oldTime = (aAny as? [String: Any])?["t"] as? Double ?? oldTime
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let resumeLatency = ProcessInfo.processInfo.systemUptime - playAsked
        let drift = landed - oldTime
        // Learn the resume latency: landing behind the old page means the standby must be started earlier.
        modeSwitchPlayLatency = min(0.3, max(0, modeSwitchPlayLatency - drift * 0.5))
        let volume = state.volume
        _ = await s.call("fade", volume, Int(Self.modeSwitchCrossfade * 1000), "in", state.isMuted)
        _ = await QTWebStandbySwitch.call(mainView, "fade", [volume, Int(Self.modeSwitchCrossfade * 1000), "out", state.isMuted])
        try? await Task.sleep(for: .milliseconds(Int(Self.modeSwitchCrossfade * 1000) + 40))
        if let end = alive() {
            // Cancelled mid-fade: the old page has gone quiet, so let the waiting load reload in the page.
            _ = await QTWebStandbySwitch.call(mainView, "volume", [volume, state.isMuted])
            return end
        }

        // 4. Promote the standby.
        promote(s, oldView: mainView)
        lastSeamlessFallback = nil
        let report = QTModeSwitchReport(videoID: s.lastSample?.videoID ?? videoID, from: from, to: item.mode,
                                        requested: oldTime, landed: landed, latency: playAsked - requestedAt + resumeLatency,
                                        gap: 0, isSeamless: true)
        lastModeSwitch = report
        QTWebVideoOutput.log.info("Song⇄Video seamless \(report.from.rawValue, privacy: .public)→\(report.to.rawValue, privacy: .public) \(report.videoID, privacy: .public): old page at \(oldTime, format: .fixed(precision: 3)) s, new at \(landed, format: .fixed(precision: 3)) s, drift \(drift, format: .fixed(precision: 3)) s, ready after \(readyAfter, format: .fixed(precision: 2)) s, handover after \(report.latency, format: .fixed(precision: 2)) s")
        onModeSwitch?(report)
        return .done
    }

    private func fallBack(_ s: QTWebStandbySwitch, _ why: String) -> QTWebStandbySwitch.Outcome {
        QTWebVideoOutput.log.info("seamless switch falls back to an in-page reload: \(why, privacy: .public)")
        lastSeamlessFallback = why
        if standby === s { standby = nil }
        s.tearDown()
        return .fallBack
    }

    /// The standby page becomes the engine's page; the old one closes.
    private func promote(_ s: QTWebStandbySwitch, oldView: WKWebView) {
        guard let view = s.webView, let window = s.window else { return }
        standby = nil
        let oldWindow = hostWindow
        let oldProxy = messageProxy
        oldProxy?.role = .retired
        s.proxy.role = .main
        s.proxy.onStandbyMessage = nil
        messageProxy = s.proxy
        webView = view
        hostWindow = window
        generation = s.generation
        isPageReady = true
        isThrottlingHiddenPage = false
        requestedVideoID = s.videoID
        playingVideoID = s.lastSample?.videoID
        lastSample = nil
        video.engineDidSwapPage(from: oldView)
        // The spectrum tap's buffered audio lives in the old page; the new page's tap starts fresh.
        audio.itemDidChange()
        oldView.configuration.userContentController.removeAllScriptMessageHandlers()
        oldView.removeFromSuperview()
        oldWindow?.close()
        // The new page's own samples take over the clock (and say when its video frame is there).
        Task { @MainActor [weak self] in
            guard let self, self.webView === view else { return }
            _ = await self.command("volume", self.state.volume, self.state.isMuted)
        }
    }
}
