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
// The track ending, or the playing page failing, mid-switch drops the standby and puts the old item back: the queue
// sees `.ended` / `.failed` as usual (`QTQueueController.loadCurrent` re-checks after the cancelled load).
// Never for a signed-in free account: each standby is a fresh watch page that may roll a pre-roll, which would be an
// ad served muted in a hidden page, and a fallback after that would report a second play on the account.
//
// Behaviour tests: Tests/QTPlaybackTests/ModeSwitchTests.swift (a fake page behind `QTWebPageIO`).

/// One seamless switch in flight.
@MainActor
final class QTWebStandbySwitch {
    enum Outcome { case done, superseded, fallBack }

    let item: QTPlaybackItem
    /// What the old page plays (restored when the switch is abandoned because that page ended or failed).
    let previousItem: QTPlaybackItem?
    let videoID: String
    let generation: Int
    let proxy: QTWebPlaybackMessageProxy
    let io: QTWebPageIO
    var webView: WKWebView?
    var window: NSWindow?
    var isReady = false
    var lastSample: QTWebPlaybackSample?
    var failed = false
    /// Set when something ended the switch from outside (`cancelStandby`).
    var cancelled: Outcome?

    init(item: QTPlaybackItem, previousItem: QTPlaybackItem?, videoID: String, generation: Int,
         proxy: QTWebPlaybackMessageProxy, io: QTWebPageIO) {
        self.item = item
        self.previousItem = previousItem
        self.videoID = videoID
        self.generation = generation
        self.proxy = proxy
        self.io = io
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
        return await io.call(webView, name, args)
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
    /// Longest the standby may wait to line up with the old page once it has buffered (seconds ahead of it).
    static let modeSwitchMaxLead: TimeInterval = 8
    /// How far ahead of the old page the held standby seeks first (a seek inside its buffer takes ~0.1–0.3 s).
    static let modeSwitchSeekLead: TimeInterval = 0.45

    func canSwitchSeamlessly(autoplay: Bool) -> Bool {
        guard configuration.seamlessModeSwitch, autoplay, state.status == .playing, state.ad == nil, !state.isBuffering,
              isPageReady, !needsFreshPage, pendingLoads.isEmpty, webView != nil, isNetworkAvailable,
              configuration.debugLoadDelay == nil else { return false }
        // A signed-in free account: no standby (a hidden muted pre-roll, and a second play report on fallback).
        // Premium plays without ads; a signed-out page has no account to report to. Unknown → the in-page reload.
        guard let account = pageAccount, account != .free else { return false }
        // Near the end the next track is about to load anyway; a switch must have time to finish (or time out)
        // well before the track does.
        let remaining = state.duration > 0 ? state.duration - state.timeline.currentTime : .infinity
        return remaining > modeSwitchStandbyTimeout + Self.modeSwitchMaxLead + 2
    }

    /// The old page ended or failed while a switch was preparing: drop the standby and put back the item that page
    /// plays, so the queue's end/failure handling sees the track it knows (and Repeat One replays the right one).
    func abandonStandbyForOldPage() {
        guard let s = standby else { return }
        cancelStandby(.superseded)
        if let previous = s.previousItem, state.item == s.item {
            state.item = previous
            video.itemDidChange(isVideo: previous.mode == .video)
        }
    }

    /// Drops a switch in flight (its page closes). `.fallBack` lets the waiting `load` continue in the page.
    func cancelStandby(_ outcome: QTWebStandbySwitch.Outcome) {
        guard let s = standby else { return }
        standby = nil
        s.cancelled = outcome
        s.tearDown()
    }

    /// Runs one seamless switch (see the file header). Returns how it ended.
    /// A requested position this far from the clock is a shift between two cuts, not the moment between asking
    /// and switching.
    static func modeSwitchShift(requested: TimeInterval, clock: TimeInterval) -> TimeInterval {
        abs(requested - clock) >= 0.75 ? requested - clock : 0
    }

    /// - Parameter shift: the new rendition's position minus the old one's for the same moment of the song (0 for
    ///   the same cut).
    func seamlessModeSwitch(to item: QTPlaybackItem, videoID: String, from: QTPlaybackMode,
                            shift: TimeInterval = 0) async -> QTWebStandbySwitch.Outcome {
        guard let mainView = webView else { return .fallBack }
        let requestedAt = ProcessInfo.processInfo.systemUptime
        let startedAt = state.timeline.currentTime
        let proxy = QTWebPlaybackMessageProxy(engine: self, role: .standby)
        let s = QTWebStandbySwitch(item: item, previousItem: state.item, videoID: videoID, generation: generation + 1,
                                   proxy: proxy, io: pageIO)
        proxy.onStandbyMessage = { [weak s] body in s?.receive(body) }
        standby = s

        // 1. The switch shows at once; the clock keeps running on the old page.
        state.item = item
        video.itemDidChange(isVideo: item.mode == .video)
        publish()

        // 2. The standby page, silent, from about where the old page will be when it has loaded (a whole second:
        // the watch URL's `t`; rounded down, so it usually lands a little behind and one short seek inside what it
        // has buffered lines it up — rounding up instead made the video wait up to a second longer).
        let target = max(0, startedAt + shift) + max(0.5, modeSwitchReadyEstimate - 0.3)
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
        components.queryItems = [URLQueryItem(name: "v", value: videoID), URLQueryItem(name: "t", value: "\(Int(target.rounded(.down)))s")]
        pageIO.load(view, URLRequest(url: components.url!))
        QTWebVideoOutput.log.info("seamless switch \(from.rawValue, privacy: .public)→\(item.mode.rawValue, privacy: .public): standby \(videoID, privacy: .public) from \(target, format: .fixed(precision: 1)) s")

        func alive() -> QTWebStandbySwitch.Outcome? {
            if let c = s.cancelled { return c }
            if standby !== s { return .superseded }
            if s.failed { return fallBack(s, "standby error") }
            if s.lastSample?.ad != nil { return fallBack(s, "standby ad") }
            return nil
        }

        /// Sleeps in short slices so a cancellation (pause, seek, the track ending…) ends the switch at once.
        func wait(_ seconds: TimeInterval) async -> QTWebStandbySwitch.Outcome? {
            let until = ProcessInfo.processInfo.systemUptime + seconds
            while true {
                if let end = alive() { return end }
                let left = until - ProcessInfo.processInfo.systemUptime
                if left <= 0 { return nil }
                try? await Task.sleep(for: .milliseconds(max(1, Int(min(left, 0.04) * 1000))))
            }
        }

        // Wait until the standby plays content (it buffers), then hold it there.
        let deadline = requestedAt + modeSwitchStandbyTimeout
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
                  let a = await pageIO.call(mainView, "sample", []) as? [String: Any], let ta = a["t"] as? Double
            else { return alive() ?? fallBack(s, "no clock") }
            if let end = alive() { return end }
            standbyTime = tb
            let ahead = tb - (ta + shift) - modeSwitchPlayLatency
            if ahead >= 0.03, ahead < Self.modeSwitchMaxLead { break }
            // Behind (the usual case, see step 2) or far ahead: seek the held standby a little ahead of the old page —
            // just past what a buffered seek takes first, further if that wasn't enough.
            attempts += 1
            if attempts > 2 { return fallBack(s, "could not line up") }
            let to = max(0, ta + shift) + (attempts == 1 ? Self.modeSwitchSeekLead : 1.2)
            _ = await s.call("seek", to)
            let seekDeadline = ProcessInfo.processInfo.systemUptime + 4
            while true {
                if let end = await wait(0.03) { return end }
                if let b = await s.call("sample") as? [String: Any], (b["rs"] as? Int ?? 0) >= 3,
                   abs((b["t"] as? Double ?? 0) - to) < 0.25 { break }
                if ProcessInfo.processInfo.systemUptime > seekDeadline { return fallBack(s, "seek timeout") }
            }
        }
        guard let a = await pageIO.call(mainView, "sample", []) as? [String: Any], let ta = a["t"] as? Double
        else { return alive() ?? fallBack(s, "no clock") }
        if let end = await wait(standbyTime - (ta + shift) - modeSwitchPlayLatency) { return end }
        let playAsked = ProcessInfo.processInfo.systemUptime
        _ = await s.call("play")
        // Playing again (a buffered resume: tens of ms).
        var landed = standbyTime
        var oldTime = ta
        for _ in 0..<50 {
            if let end = alive() { return end }
            let bAny = await s.call("sample")
            let aAny = await pageIO.call(mainView, "sample", [])
            if let b = bAny as? [String: Any], (b["paused"] as? Bool) == false, let tb = b["t"] as? Double, tb > standbyTime + 0.005 {
                landed = tb
                oldTime = (aAny as? [String: Any])?["t"] as? Double ?? oldTime
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let resumeLatency = ProcessInfo.processInfo.systemUptime - playAsked
        let drift = landed - (oldTime + shift)
        // Learn the resume latency: landing behind the old page means the standby must be started earlier.
        modeSwitchPlayLatency = min(0.3, max(0, modeSwitchPlayLatency - drift * 0.5))
        let volume = state.volume
        _ = await s.call("fade", volume, Int(Self.modeSwitchCrossfade * 1000), "in", state.isMuted)
        _ = await pageIO.call(mainView, "fade", [volume, Int(Self.modeSwitchCrossfade * 1000), "out", state.isMuted])
        if let end = await wait(Self.modeSwitchCrossfade + 0.04) {
            // Cancelled mid-fade: the old page was fading out — give it its volume back (it keeps playing until the
            // waiting load reloads it, or it is what plays on after the track ended / a stop).
            _ = await pageIO.call(mainView, "volume", [state.volume, state.isMuted])
            return end
        }

        // 4. Promote the standby.
        promote(s, oldView: mainView)
        lastSeamlessFallback = nil
        let report = QTModeSwitchReport(videoID: s.lastSample?.videoID ?? videoID, from: from, to: item.mode,
                                        requested: oldTime + shift, landed: landed, latency: playAsked - requestedAt + resumeLatency,
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
