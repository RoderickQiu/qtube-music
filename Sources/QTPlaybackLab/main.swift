// QTPlaybackLab — drives QTWebPlaybackEngine + QTQueueController + QTNowPlayingController against the real
// YouTube Music web player. Anonymous (non-persistent data store) and silent (media volume pinned to 0).
// Never activates: no Dock icon, no windows on screen, no focus change.
//
//   swift run --scratch-path .build/playback QTPlaybackLab [--ids a,b,c] [--scenario basic|advance|cue|power|errors|switch] [--queries "a|b|c"] [--count N]
//
// Prints one line per engine state change and a PASS/FAIL summary per check.

import AppKit
import Foundation
import QTCore
import QTInnerTube
import QTPlayback
import WebKit

let defaultIDs = ["dQw4w9WgXcQ", "kJQP7kiw5Fk", "JGwWNGJdvx8", "9bZkp7q19f0", "OPf0YbXqDm0", "fJ9rUzIMcZQ",
                  "hT_nvWreIhg", "RgKAFK5djSk", "YQHsXMglC9A", "60ItHLz5WEA", "CevxZvSJLk8"]

struct LabOptions {
    var ids = defaultIDs
    var scenario = "basic"
    var count = 10
    var queries = ["Ed Sheeran Perfect", "Adele Hello", "Coldplay Yellow"]

    init(_ args: [String]) {
        var it = args.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--ids": ids = (it.next() ?? "").split(separator: ",").map(String.init)
            case "--scenario": scenario = it.next() ?? scenario
            case "--count": count = Int(it.next() ?? "") ?? count
            case "--queries": queries = (it.next() ?? "").split(separator: "|").map(String.init)
            case "--help", "-h":
                print("QTPlaybackLab [--ids a,b,c] [--scenario basic|advance|cue|power|errors|switch] [--queries a|b|c] [--count N]")
                exit(0)
            default: break
            }
        }
    }
}

@MainActor
final class Lab {
    let options: LabOptions
    let engine: QTWebPlaybackEngine
    let nowPlaying = QTNowPlayingController()
    let controller: QTQueueController
    let start = ProcessInfo.processInfo.systemUptime
    var results: [(String, Bool, String)] = []
    var lastLine = ""
    var sawAd = false
    var maxAdRemaining: TimeInterval = 0
    var sawSkippableCountdown = false

    init(options: LabOptions) {
        self.options = options
        engine = QTWebPlaybackEngine(configuration: .init(isSilent: true), dataStore: .nonPersistent())
        controller = QTQueueController(engine: engine, nowPlaying: nowPlaying)
    }

    var now: Double { ProcessInfo.processInfo.systemUptime - start }

    func log(_ s: String) {
        print(String(format: "%7.2f  ", now) + s)
        fflush(stdout)
    }

    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        results.append((name, ok, detail))
        log("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }

    func watchState() {
        let stream = engine.stateUpdates()
        Task { @MainActor in
            for await s in stream {
                let vid = s.item.map { QTWebPlaybackEngine.videoID(for: $0) } ?? "-"
                var line = "state \(s.status) vid=\(vid) t=\(String(format: "%.1f", s.timeline.time)) d=\(String(format: "%.0f", s.duration)) rate=\(s.timeline.rate)"
                if s.isBuffering { line += " buffering" }
                if let ad = s.ad {
                    sawAd = true
                    maxAdRemaining = max(maxAdRemaining, ad.remaining)
                    if let k = ad.skippableIn, k > 0 { sawSkippableCountdown = true }
                    line += " AD remaining=\(String(format: "%.0f", ad.remaining)) skippableIn=\(ad.skippableIn.map { String(format: "%.0f", $0) } ?? "never")"
                }
                if line != lastLine { log(line); lastLine = line }
            }
        }
    }

    func wait(_ timeout: Double, _ what: String, until condition: () -> Bool) async -> Bool {
        let deadline = now + timeout
        while now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        log("timeout waiting for \(what)")
        return condition()
    }

    func track(_ id: String) -> QTTrack {
        QTTrack(videoId: id, title: id, artists: [QTArtistRef(name: "Lab")], duration: 0, musicVideoType: .omv)
    }

    /// Waits for content (not an ad) to be playing; skips ads as soon as YouTube allows.
    func waitForContent(_ timeout: Double = 75) async -> Bool {
        let deadline = now + timeout
        var nextProbe = now + 5
        while now < deadline {
            if now > nextProbe {
                nextProbe = now + 5
                let raw = await engine.debugSample()
                log("probe \(raw.map { String(describing: $0) } ?? "nil")")
            }
            let s = engine.state
            if let ad = s.ad, ad.canSkip {
                log("skipping ad")
                engine.skipAd()
                try? await Task.sleep(for: .milliseconds(800))
            }
            if s.ad == nil, s.status == .playing, s.duration > 0, !s.isBuffering { return true }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return false
    }

    func systemNowPlaying() -> String {
        let script = """
        function run() {
          $.NSBundle.bundleWithPath("/System/Library/PrivateFrameworks/MediaRemote.framework").load;
          const R = $.NSClassFromString("MRNowPlayingRequest");
          const pp = R.localNowPlayingPlayerPath;
          let title = "-";
          try { const item = R.localNowPlayingItem; title = item.isNil() ? "nil" : ObjC.unwrap(item.metadata.title); } catch (e) {}
          return (pp.isNil() ? "nil" : ObjC.unwrap(pp.description)) + " | " + title;
        }
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-l", "JavaScript", "-e", script]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func cpu(of pid: pid_t) -> Double? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "%cpu=", "-p", "\(pid)"]
        let out = Pipe()
        p.standardOutput = out
        try? p.run()
        p.waitUntilExit()
        return Double(String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    /// ps %cpu is a decaying average; sample `top` style by measuring CPU time over an interval instead.
    func cpuTime(of pid: pid_t) -> Double? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "time=", "-p", "\(pid)"]
        let out = Pipe()
        p.standardOutput = out
        try? p.run()
        p.waitUntilExit()
        guard let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        // [[hh:]mm:]ss.cc
        var total = 0.0
        for part in s.split(separator: ":") { total = total * 60 + (Double(part) ?? 0) }
        return total
    }

    func measureCPU(_ label: String, seconds: Double) async -> Double? {
        guard let pid = engine.webContentProcessIdentifier, let a = cpuTime(of: pid) else { return nil }
        try? await Task.sleep(for: .seconds(seconds))
        guard let b = cpuTime(of: pid) else { return nil }
        let pct = (b - a) / seconds * 100
        log(String(format: "CPU %@: WebContent pid %d %.1f%%", label, pid, pct))
        return pct
    }

    // MARK: Scenarios

    func basic() async {
        let ids = options.ids
        let tracks = ids.map(track)
        log("play \(ids[0]) (queue of \(ids.count))")
        let t0 = now
        await controller.play(tracks, startingAt: 0, source: QTQueueSource(kind: .playlist, id: "lab", title: .verbatim("Lab")))
        check("load returns", engine.state.item != nil && controller.lastFailure == nil,
              "\(String(format: "%.1f", now - t0)) s, failure=\(String(describing: controller.lastFailure))")

        let content = await waitForContent()
        check("content plays (after any ad)", content, sawAd ? "ad seen, max remaining \(Int(maxAdRemaining)) s, countdown seen=\(sawSkippableCountdown)" : "no ad this time")
        guard content else { return }

        let a = engine.state.time
        try? await Task.sleep(for: .seconds(4))
        let b = engine.state.time
        check("time advances", (b - a) > 3 && (b - a) < 5.5, String(format: "%.2f → %.2f", a, b))

        let wk = await engine.webKitNowPlayingSessionInfo()
        let sys = systemNowPlaying()
        log("WebKit session info: \(String(describing: wk)); system Now Playing: \(sys)")
        check("system Now Playing is ours, not WebKit's", sys.contains("QTPlaybackLab") && !sys.contains("WebKit"), sys)
        check("Now Playing title published", nowPlaying.snapshot?.videoID == ids[0], nowPlaying.snapshot.map { "\($0.title) \(Int($0.elapsed))/\(Int($0.duration)) rate \($0.rate)" } ?? "nil")

        _ = await measureCPU("playing", seconds: 5)

        engine.seek(to: 60)
        try? await Task.sleep(for: .seconds(2.5))
        let afterSeek = engine.state.time
        check("seek to 60", afterSeek > 59 && afterSeek < 64, String(format: "t=%.2f", afterSeek))

        controller.pause()
        try? await Task.sleep(for: .seconds(1.5))
        let p1 = engine.state.time
        _ = await measureCPU("paused", seconds: 5)
        let p2 = engine.state.time
        check("pause holds position", engine.state.status == .paused && abs(p2 - p1) < 0.3, String(format: "%.2f → %.2f status %@", p1, p2, "\(engine.state.status)"))
        controller.play()
        let resumed = await wait(8, "resume") { self.engine.state.status == .playing && self.engine.state.time > p2 + 0.5 }
        check("resume", resumed)

        let d = engine.state.duration
        engine.seek(to: d - 4)
        log("seek near end (\(Int(d - 4))/\(Int(d)))")
        let tEnd = now
        let advanced = await wait(30, "advance to track 2") {
            self.controller.nowPlayingTrack?.videoId == ids[1] && self.engine.state.item.map { QTWebPlaybackEngine.videoID(for: $0) } == ids[1]
        }
        check("natural end → queue advances", advanced, String(format: "%.1f s after seek", now - tEnd))
        let next = await waitForContent()
        check("next track plays", next && engine.state.item?.track.videoId == ids[1],
              String(format: "%.1f s after end seek, t=%.1f", now - tEnd, engine.state.time))
        let sys2 = systemNowPlaying()
        check("Now Playing follows track 2, single entry", sys2.contains("QTPlaybackLab") && !sys2.contains("WebKit") && nowPlaying.snapshot?.videoID == ids[1], sys2)

        await controller.previous()  // > 3 s in? restart; else back to track 1
        try? await Task.sleep(for: .seconds(1))
        log("previous → now \(controller.nowPlayingTrack?.videoId ?? "-") t=\(String(format: "%.1f", engine.state.time))")
    }

    func advanceMany() async {
        let ids = Array(options.ids.prefix(options.count + 1))
        await controller.play(ids.map(track), startingAt: 0)
        var transitions: [Double] = []
        for i in 0..<(ids.count - 1) {
            guard await waitForContent() else {
                check("track \(i + 1) plays", false, ids[i])
                return
            }
            let d = engine.state.duration
            engine.seek(to: d - 3)
            let t = now
            let ok = await wait(40, "advance from \(ids[i])") { self.controller.nowPlayingTrack?.videoId == ids[i + 1] }
            guard ok else {
                check("advance \(i + 1) → \(i + 2)", false, "stuck on \(controller.nowPlayingTrack?.videoId ?? "-")")
                return
            }
            let started = await waitForContent()
            transitions.append(now - t)
            log(String(format: "advance %d → %d: %@ in %.1f s (incl. ads)", i + 1, i + 2, started ? "playing" : "NOT playing", now - t))
            if !started {
                check("advance \(i + 1) → \(i + 2)", false, "next didn't start")
                return
            }
        }
        check("\(ids.count - 1) advances in a row without a stall", true,
              "transitions " + transitions.map { String(format: "%.1f", $0) }.joined(separator: ", ") + " s")
    }

    /// Restore path: a paused first load (fresh page) and a paused load on a ready page, then play.
    func cued() async {
        let ids = options.ids
        await controller.play(ids.map(track), startingAt: 0, startTime: 50, autoplay: false)
        try? await Task.sleep(for: .seconds(4))
        let s1 = engine.state
        check("paused first load stays paused", controller.lastFailure == nil && s1.status == .paused && s1.timeline.rate == 0,
              "status \(s1.status) t=\(String(format: "%.1f", s1.time)) d=\(Int(s1.duration)) ad=\(s1.ad != nil)")
        controller.play()
        let content = await waitForContent()
        check("plays from the restored position", content && engine.state.time >= 49, String(format: "t=%.1f", engine.state.time))

        await controller.jump(to: controller.queue.autoplay[0])  // page ready now
        controller.pause()
        let t0 = now
        await controller.play(ids.map(track), startingAt: 2, startTime: 30, autoplay: false)
        let s2 = engine.state
        check("cued load on a ready page", controller.lastFailure == nil && s2.status == .paused,
              String(format: "%.1f s, status %@ t=%.1f d=%.0f", now - t0, "\(s2.status)", s2.time, s2.duration))
        try? await Task.sleep(for: .seconds(2))
        check("cued item doesn't start by itself", engine.state.status == .paused, "\(engine.state.status)")
        controller.play()
        let content2 = await waitForContent()
        check("cued item plays on demand", content2 && engine.state.time >= 29 && engine.state.item?.track.videoId == ids[2],
              String(format: "t=%.1f", engine.state.time))
    }

    /// Power: WebContent CPU while playing (lowest video quality), just after pausing, and once the page is frozen.
    func power() async {
        await controller.play(options.ids.map(track), startingAt: 0)
        guard await waitForContent() else { return check("content plays", false) }
        try? await Task.sleep(for: .seconds(4))
        let media = await engine.debugMediaInfo()
        log("media \(media.map { String(describing: $0) } ?? "nil")")
        let height = (media?["height"] as? Double) ?? Double((media?["height"] as? Int) ?? 0)
        check("lowest video rendition while no video is shown", height > 0 && height <= 240,
              "\(media?["quality"] ?? "?") \(Int(height))p, volume \(media?["volume"] ?? "?")")
        check("media volume pinned to 0 (silent)", (media?["volume"] as? Double) == 0)
        let playing = await measureCPU("playing", seconds: 10) ?? 100
        controller.pause()
        try? await Task.sleep(for: .seconds(1))
        let unfrozen = await measureCPU("paused, not yet frozen", seconds: 4) ?? 100
        _ = await wait(15, "freeze") { self.engine.isPageFrozen }
        check("page freezes while paused", engine.isPageFrozen)
        try? await Task.sleep(for: .seconds(3))
        let frozen = await measureCPU("paused, frozen", seconds: 20) ?? 100
        check("paused engine idles under 1% CPU", frozen < 1, String(format: "playing %.1f%%, paused %.1f%% → frozen %.2f%%", playing, unfrozen, frozen))
        let t = engine.state.time
        controller.play()
        let resumed = await wait(10, "resume after freeze") { self.engine.state.status == .playing && self.engine.state.time > t + 1 }
        check("resumes from a frozen page", resumed, String(format: "t=%.1f", engine.state.time))
        engine.seek(to: engine.state.duration - 3)
        let advanced = await wait(30, "advance after thaw") { self.controller.nowPlayingTrack?.videoId == self.options.ids[1] }
        check("track end still advances after a freeze", advanced)
    }

    /// Unplayable ids fail fast with a specific error and the queue skips to the next playable track.
    func errors() async {
        var failures: [QTPlaybackFailureEvent] = []
        controller.onFailure = { failures.append($0) }
        let bad = ["xxxxxxxxxxx", "ne3372368359"]  // made-up id (mock catalog style), well-formed but nonexistent
        let ids = bad + [options.ids[0]]
        let t0 = now
        await controller.play(ids.map(track), startingAt: 0)
        let reached = await wait(60, "skip to a playable track") { self.controller.nowPlayingTrack?.videoId == ids[2] }
        check("unplayable items are skipped", reached && failures.count == 2,
              String(format: "%.1f s; ", now - t0) + failures.map { "\($0.track.videoId): \($0.error) skipped=\($0.skipped)" }.joined(separator: "; "))
        let content = await waitForContent()
        check("the next playable track plays", content)
    }

    /// M5 acceptance (stage-video): Song⇄Video at the same timestamp. For each query (`--queries "a|b|c"`) the song
    /// (ATV) is found by an anonymous search, its music video through `counterpart(for:)` (next, then search);
    /// it plays muted from 0:30, switches to the video and back, and logs both positions of every switch.
    func switching() async {
        let client = QTInnerTubeClient()
        var reports: [QTModeSwitchReport] = []
        engine.onModeSwitch = { reports.append($0) }
        for query in options.queries {
            guard let song = try? await client.search(query, filter: .songs).songs.first(where: { $0.musicVideoType == .atv }) else {
                check("\(query): song found", false); continue
            }
            var track = song
            if track.counterpart == nil { track.counterpart = try? await client.counterpart(for: song) }
            guard let mv = track.counterpart, mv.musicVideoType.isVideo else {
                check("\(query): music video found", false, song.videoId); continue
            }
            log("\(query): song \(song.videoId) ⇄ video \(mv.videoId)")
            await controller.play([track], startTime: 30, autoplay: true, mode: .song)
            guard await waitForContent() else { check("\(query): song plays", false); continue }
            try? await Task.sleep(for: .seconds(4))
            for target in [QTPlaybackMode.video, .song] {
                let before = reports.count
                let asked = controller.currentTime
                await controller.setMode(target)
                let landed = await wait(30, "switch to \(target)") { reports.count > before }
                let r = reports.last
                check("\(query): \(target == .video ? "song → video" : "video → song") keeps the position",
                      landed && abs(r?.offset ?? 99) <= 0.5,
                      r.map { String(format: "asked %.2f s, requested %.2f s, landed %.2f s, offset %+.2f s, latency %.2f s, queue %d",
                                     asked, $0.requested, $0.landed, $0.offset, $0.latency, controller.queue.autoplay.count) } ?? "no report")
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    /// Diagnostics: what the page looks like a few seconds into loading `--ids` first id.
    func probe() async {
        let id = options.ids[0]
        Task { await controller.play([track(id)], startingAt: 0) }
        for _ in 0..<4 {
            try? await Task.sleep(for: .seconds(4))
            let r = await engine.debugEvaluate("""
            const p = document.getElementById('movie_player');
            let st = null; try { st = p && p.getPlayerResponse && p.getPlayerResponse(); st = st && st.playabilityStatus; } catch (e) { st = 'err ' + e; }
            return JSON.stringify({ href: location.href, player: !!p, api: !!(p && p.getPlayerState), ps: p && p.getPlayerState ? p.getPlayerState() : null,
              playability: st, bridge: !!window.__qtBridge, title: document.title });
            """)
            log("probe \(r ?? "nil")")
        }
    }

    func run() async -> Int32 {
        watchState()
        switch options.scenario {
        case "probe": await probe()
        case "power": await power()
        case "errors": await errors()
        case "cue": await cued()
        case "advance": await advanceMany()
        case "switch": await switching()
        default: await basic()
        }
        engine.shutdown()
        nowPlaying.clear()
        let failed = results.filter { !$0.1 }
        print("\n== \(results.count - failed.count)/\(results.count) checks passed ==")
        for r in results { print("\(r.1 ? "PASS" : "FAIL")  \(r.0)\(r.2.isEmpty ? "" : " — \(r.2)")") }
        return failed.isEmpty ? 0 : 1
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let options = LabOptions(CommandLine.arguments)
Task { @MainActor in
    let lab = Lab(options: options)
    let code = await lab.run()
    exit(code)
}
app.run()
