// QTNativeSpike — M5 native playback engine spike (docs/native-engine-spike.md). DEV ONLY, headless, MUTED.
// Never activates anything: no NSApplication, no windows, no Dock icon. The audio engine's output volume is 0.
//
//   swift run --scratch-path .build/<you> QTNativeSpike clients [--ids a,b] [--signed-in]
//       Per client × track: playability, audio formats, plain URL vs signatureCipher/n, SABR-only.
//   swift run … QTNativeSpike bench [--ids a,b] [--count N] [--clients IOS,ANDROID_VR] [--signed-in] [--json out.json]
//       Resolve → download → AVAudioFile → AVAudioEngine (muted) per track: success rate and time-to-first-audio,
//       plus CPU while playing (EQ + FFT tap on), a gapless seam render, a crossfade, the EQ and the spectrum.
//   swift run … QTNativeSpike cipher [--signed-in]
//       Current player hash + signatureTimestamp, EJS-in-JavaScriptCore solve timings, and whether a deciphered
//       WEB_REMIX URL actually downloads (PO-token enforcement).
//   swift run … QTNativeSpike avplayer [--ids a,b]
//       AVQueuePlayer progressive path: AAC ready/playing time; Opus/WebM playability.
//
// --signed-in uses the shared dev session (QTDevSharedKeychainStore) read-only; cookie values are never printed.
// Only the `player` endpoint and googlevideo media are requested — no playback-tracking pings, so nothing is
// written to the account's history.

import AVFoundation
import Darwin
import Foundation
import QTAuth
import QTInnerTube
import QTPlayback

#if DEBUG
/// 12 tracks from the prototype's catalog (CJK, Vietnamese, English) + 11 widely available music videos.
let defaultIDs = ["wYBeTZb2a0A", "KqcN6C8tpnA", "bYbNYnI3Gfk", "H7CeHBWOwUs", "psZ1g9fMfeo", "DlqSN6Im3F8",
                  "JM3e7uChFC8", "WMqMNeF34Ec", "DYptgVvkVLQ", "2Vv-BfVoq4g", "0yE4wEi8CFM", "H4gkj7Cg2X8",
                  "dQw4w9WgXcQ", "kJQP7kiw5Fk", "JGwWNGJdvx8", "9bZkp7q19f0", "OPf0YbXqDm0", "fJ9rUzIMcZQ",
                  "hT_nvWreIhg", "RgKAFK5djSk", "YQHsXMglC9A", "60ItHLz5WEA", "CevxZvSJLk8"]

struct SpikeOptions {
    var command = "help"
    var ids = defaultIDs
    var count: Int?
    var clients: [QTNativeStreamClient] = [.iOS, .android, .androidVR]
    var signedIn = false
    var clientsGiven = false
    var jsonPath: String?

    init(_ args: [String]) {
        var it = args.dropFirst().makeIterator()
        if let c = it.next() { command = c }
        while let a = it.next() {
            switch a {
            case "--ids": ids = (it.next() ?? "").split(separator: ",").map(String.init)
            case "--count": count = Int(it.next() ?? "")
            case "--clients":
                clientsGiven = true
                clients = (it.next() ?? "").split(separator: ",").compactMap { QTNativeStreamClient.named(String($0)) }
            case "--signed-in": signedIn = true
            case "--json": jsonPath = it.next()
            default: break
            }
        }
        if let count { ids = Array(ids.prefix(count)) }
    }
}

func out(_ s: String) {
    print(s)
    fflush(stdout)
}

func ms(_ s: Double?) -> String { s.map { String(format: "%5.0f ms", $0 * 1000) } ?? "      -" }

/// CPU seconds (user + system) this process has used.
func processCPUSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
    return s(usage.ru_utime) + s(usage.ru_stime)
}

func median(_ xs: [Double]) -> Double? {
    guard !xs.isEmpty else { return nil }
    let s = xs.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

func percentile(_ xs: [Double], _ p: Double) -> Double? {
    guard !xs.isEmpty else { return nil }
    let s = xs.sorted()
    return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
}

func credentials(_ signedIn: Bool) async throws -> QTInnerTubeCredentials? {
    guard signedIn else { return nil }
    let store = QTSessionStore(store: QTDevSharedKeychainStore())
    guard let session = try await store.restore() else {
        out("no dev session in the shared Keychain item — run QTDevSession import first")
        exit(1)
    }
    out("signed in: \(session.cookies.count) cookies, premium=\(session.account?.isPremium.map(String.init) ?? "?")")
    return await store.credentials()
}

@MainActor
struct Spike {
    let options: SpikeOptions

    func run() async throws {
        switch options.command {
        case "clients": try await clientsMatrix()
        case "bench": try await bench()
        case "cipher": try await cipher()
        case "avplayer": try await avplayer()
        default:
            out("QTNativeSpike clients|bench|cipher|avplayer [--ids a,b] [--count N] [--clients A,B] [--signed-in] [--json path]")
        }
    }

    // MARK: clients

    func clientsMatrix() async throws {
        let creds = try await credentials(options.signedIn)
        let resolver = QTNativeStreamResolver(credentials: creds)
        let clients = QTNativeStreamClient.all
        var ok: [String: Int] = [:]
        for id in options.ids {
            out("\(id)")
            for client in clients {
                do {
                    let r = try await resolver.player(videoId: id, client: client)
                    let audio = r.audioFormats.map { f in
                        "\(f.itag)\(f.url != nil ? "" : (f.signatureCipher != nil ? "c" : "-"))\(f.urlHasNParameter ? "n" : "")"
                    }.joined(separator: " ")
                    if r.playability == .ok, r.audioFormats.contains(where: { $0.url != nil || $0.signatureCipher != nil }) {
                        ok[client.name, default: 0] += 1
                    }
                    out("  \(client.name.padding(toLength: 15, withPad: " ", startingAt: 0)) \(r.signedIn ? "auth" : "anon") \(r.playability) audio: \(audio)\(r.hasServerABR ? " [sabr]" : "")")
                } catch {
                    out("  \(client.name) error \(error)")
                }
            }
        }
        out("\nformats with URL or cipher (per client, of \(options.ids.count)):")
        for c in clients { out("  \(c.name): \(ok[c.name, default: 0])") }
        out("legend: itag; c = signatureCipher; n = throttling n parameter; - = no URL (SABR only)")
    }

    // MARK: bench

    struct TrackResult: Codable {
        var id: String
        var ok: Bool
        var client: String?
        var itag: Int?
        var bytes: Int?
        var resolve: Double?
        var firstByte: Double?
        var download: Double?
        var open: Double?
        var firstAudio: Double?
        var firstSound: Double?
        var decodedMinusDeclaredMs: Double?
        var error: String?
        var fallbacks: [String]
    }

    func bench() async throws {
        defer { QTNativeStreamDownloader.purge() }
        try await QTNativeSolverSource.ensureDownloaded()
        let creds = try await credentials(options.signedIn)
        let resolver = QTNativeStreamResolver(credentials: creds)
        let clients = options.clientsGiven ? options.clients
            : (options.signedIn ? [.webRemix, .tvSamsung, .iOS] : [.visionOS, .tvSamsung, .iOS, .android, .androidVR, .tvSimply, .webRemix])
        out("clients: \(clients.map(\.name).joined(separator: " → "))")
        let graph = QTNativeAudioGraph()
        var results: [TrackResult] = []
        var files: [AVAudioFile] = []
        out("track        client      itag   resolve 1st chunk download     open 1st frame 1st sound  Δdur    bytes")
        for id in options.ids {
            let t0 = ProcessInfo.processInfo.systemUptime
            var r = TrackResult(id: id, ok: false, fallbacks: [])
            do {
                // Resolve + download per client; a googlevideo 403 (PO-token enforcement) falls through to the next.
                var resolved: (QTNativeResolvedStream, QTNativeStreamDownloader.Result)?
                for client in clients {
                    do {
                        let stream = try await resolver.resolve(videoId: id, clients: [client])
                        do {
                            resolved = (stream, try await QTNativeStreamDownloader.download(stream))
                            break
                        } catch {
                            r.fallbacks.append("\(client.name): media \(error)")
                        }
                    } catch {
                        r.fallbacks.append("\(error)")
                    }
                }
                guard let (stream, dl) = resolved else { throw QTNativeStreamError.noPlayableAudio("all clients failed") }
                r.client = stream.client.name
                r.itag = stream.format.itag
                r.resolve = stream.resolveSeconds
                r.bytes = dl.bytes
                r.firstByte = dl.firstByteSeconds
                r.download = dl.totalSeconds
                let o0 = ProcessInfo.processInfo.systemUptime
                let file = try AVAudioFile(forReading: dl.file)
                r.open = ProcessInfo.processInfo.systemUptime - o0
                if let declared = stream.durationSeconds {
                    // lengthSeconds is whole seconds; the `dur` URL param is ms-precise.
                    let dur = URLComponents(url: stream.url, resolvingAgainstBaseURL: false)?.queryItems?
                        .first { $0.name == "dur" }?.value.flatMap(Double.init) ?? declared
                    r.decodedMinusDeclaredMs = (Double(file.length) / file.processingFormat.sampleRate - dur) * 1000
                }
                try graph.play(file)
                // First audio = the node is rendering the track's frames (what a listener would hear, unless the
                // master starts with silence — `firstSound` is the first non-silent buffer, for reference).
                let deadline = ProcessInfo.processInfo.systemUptime + 8
                while ProcessInfo.processInfo.systemUptime < deadline {
                    if r.firstAudio == nil, graph.currentTime > 0 { r.firstAudio = ProcessInfo.processInfo.systemUptime - t0 }
                    if r.firstAudio != nil, graph.firstSignalUptime != nil { break }
                    try await Task.sleep(for: .milliseconds(1))
                }
                r.firstSound = graph.firstSignalUptime.map { $0 - t0 }
                r.ok = r.firstAudio != nil
                if !r.ok { r.error = "no rendered frame within 8 s" }
                guard graph.isMuted else { fatalError("output must stay muted") }
                files.append(file)
            } catch {
                r.error = "\(error)"
            }
            results.append(r)
            if r.ok {
                out("\(id)  \((r.client ?? "").padding(toLength: 10, withPad: " ", startingAt: 0)) \(String(r.itag ?? 0).padding(toLength: 4, withPad: " ", startingAt: 0)) \(ms(r.resolve)) \(ms(r.firstByte)) \(ms(r.download)) \(ms(r.open)) \(ms(r.firstAudio)) \(ms(r.firstSound)) \(String(format: "%+5.0f", r.decodedMinusDeclaredMs ?? .nan)) \(r.bytes ?? 0)")
            } else {
                out("\(id)  FAILED \(r.error ?? "")")
            }
            for f in r.fallbacks { out("             ↳ \(f)") }
        }
        graph.stop()

        let good = results.filter(\.ok)
        out("\nsuccess: \(good.count)/\(results.count)")
        let ttfa = good.compactMap(\.firstAudio)
        out("time to first audio (request → rendered frame): median \(ms(median(ttfa))), p90 \(ms(percentile(ttfa, 0.9))), max \(ms(ttfa.max()))")
        let warm = Array(good.dropFirst()).compactMap(\.firstAudio)
        out("  warm (player script + solver already cached): median \(ms(median(warm))), p90 \(ms(percentile(warm, 0.9))), max \(ms(warm.max()))")
        out("  resolve median \(ms(median(good.compactMap(\.resolve)))) · download median \(ms(median(good.compactMap(\.download)))) · open median \(ms(median(good.compactMap(\.open))))")
        let byClient = Dictionary(grouping: good, by: { $0.client ?? "?" }).mapValues(\.count)
        out("  served by: \(byClient.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        await appendRunLog(signedIn: options.signedIn, ok: good.count, total: results.count, servedBy: byClient,
                           playerHash: await resolver.loadedPlayerHash, medianTTFA: median(ttfa))

        guard files.count >= 2 else { return }
        try await cpuAndFeatures(files: files)
        if let path = options.jsonPath {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(results).write(to: URL(fileURLWithPath: path))
            out("wrote \(path)")
        }
    }

    /// Breakage tracking: one JSON line per bench run in the user Caches folder (no URLs, no session data). Run the
    /// bench now and then; a drop in `ok` or a new `playerHash` next to failures is the churn this spike measures.
    func appendRunLog(signedIn: Bool, ok: Int, total: Int, servedBy: [String: Int], playerHash: String?,
                      medianTTFA: Double?) async {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "com.roderickqiu.qtube.native-spike", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "runs.jsonl")
        let entry: [String: Any] = [
            "date": ISO8601DateFormatter().string(from: Date()), "signedIn": signedIn, "ok": ok, "total": total,
            "servedBy": servedBy, "playerHash": playerHash ?? NSNull(), "medianTTFAms": medianTTFA.map { Int($0 * 1000) } ?? NSNull(),
        ]
        guard var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
        out("  logged to \(url.path)")
    }

    func cpuAndFeatures(files: [AVAudioFile]) async throws {
        // Gapless seam, offline (no device): last second of track i + first second of track i+1 on one node.
        out("\ngapless seam (offline render): a track cut in two segments and scheduled back to back vs played straight through")
        for file in files.prefix(3) {
            let seam = try QTNativeAudioGraph.seamDifference(file)
            out("  \(file.url.lastPathComponent): max |difference| \(seam.maxDifference) over \(seam.frames) frames; longest silent run at the cut \(seam.silentFramesAtCut)")
        }

        // CPU: idle baseline, then playing with EQ + FFT tap, then the crossfade.
        let graph = QTNativeAudioGraph()
        let idle0 = processCPUSeconds(), w0 = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(for: .seconds(3))
        let idleCPU = (processCPUSeconds() - idle0) / (ProcessInfo.processInfo.systemUptime - w0)
        try graph.play(files[0])
        graph.setEQ(gains: [6, 4, 2, 0, -2, -2, 0, 2, 4, 6])
        try await Task.sleep(for: .seconds(1))
        let c0 = processCPUSeconds(), p0 = ProcessInfo.processInfo.systemUptime
        var spectra: [[Float]] = []
        for _ in 0..<100 {   // 10 s, visualizer polling at 10 Hz (the Stage polls at display rate; cost is the tap)
            try await Task.sleep(for: .milliseconds(100))
            spectra.append(graph.spectrum(bandCount: 32))
        }
        let playCPU = (processCPUSeconds() - c0) / (ProcessInfo.processInfo.systemUptime - p0)
        out("\nCPU (one core = 100%): idle \(String(format: "%.1f", idleCPU * 100))% · playing AAC + 10-band EQ + FFT tap \(String(format: "%.1f", playCPU * 100))%")
        let nonZero = spectra.filter { $0.contains { $0 > 0.05 } }.count
        let avg = spectra.last.map { $0.map { String(format: "%.2f", $0) }.prefix(12).joined(separator: " ") } ?? "-"
        out("spectrum: \(nonZero)/\(spectra.count) polls had signal; last 32-band frame (first 12): \(avg)")
        out("EQ bands: \(graph.eq.bands.map { "\(Int($0.frequency))Hz \(String(format: "%+.0f", $0.gain))" }.joined(separator: ", "))")

        // Crossfade 4 s into the next track.
        let x0 = processCPUSeconds(), xw = ProcessInfo.processInfo.systemUptime
        let before = graph.currentTime
        await graph.crossfade(to: files[1], duration: 4)
        let xCPU = (processCPUSeconds() - x0) / (ProcessInfo.processInfo.systemUptime - xw)
        let vols = graph.activeNodeVolumes
        out("crossfade 4 s: outgoing was at \(String(format: "%.1f", before)) s; after: incoming at \(String(format: "%.1f", graph.currentTime)) s, volumes active \(vols.active) standby \(vols.standby); CPU during fade \(String(format: "%.1f", xCPU * 100))%")

        // Gapless live: enqueue the next file behind the current one and check there is no silent run at the seam.
        graph.stop()
        let tail = AVAudioFramePosition(2 * files[1].processingFormat.sampleRate)
        let g = QTNativeAudioGraph()
        try g.start(format: files[1].processingFormat)
        g.resetMeters()
        let node = files[1]
        node.framePosition = max(0, node.length - tail)
        try g.play(node)
        g.enqueueGapless(files[2 % files.count])
        try await Task.sleep(for: .seconds(4))
        out("gapless live (muted device): longest silent run after first signal \(g.longestSilentRunFrames) frames across the seam")
        g.stop()
    }

    // MARK: cipher

    func cipher() async throws {
        try await QTNativeSolverSource.ensureDownloaded()
        let creds = try await credentials(options.signedIn)
        let resolver = QTNativeStreamResolver(credentials: creds)
        let script = try await resolver.script()
        out("player \(script.playerHash) · sts \(script.signatureTimestamp.map(String.init) ?? "?") · \(script.playerByteCount / 1024) KB fetched in \(ms(script.fetchSeconds))")
        for client in [QTNativeStreamClient.webRemix, .tvSamsung, .tvSimply] {
            for id in options.ids.prefix(options.count ?? 3) {
                do {
                    let r = try await resolver.player(videoId: id, client: client)
                    let itags = r.audioFormats.map { "\($0.itag)" }.joined(separator: ",")
                    guard r.playability == .ok, let f = r.bestPlayableAudio, let cipher = f.signatureCipher ?? f.url?.absoluteString else {
                        out("\(client.name) \(id) \(r.signedIn ? "auth" : "anon") \(r.playability) itags [\(itags)]\(r.hasServerABR ? " sabr" : "")")
                        continue
                    }
                    let s0 = ProcessInfo.processInfo.systemUptime
                    let signed = f.signatureCipher != nil ? try script.decipher(cipher) : f.url!
                    let s1 = ProcessInfo.processInfo.systemUptime
                    let final = try script.transformN(signed)
                    let s2 = ProcessInfo.processInfo.systemUptime
                    let stream = QTNativeResolvedStream(videoId: id, client: client, format: f, url: final,
                                                        userAgent: client.userAgent, durationSeconds: r.durationSeconds,
                                                        resolveSeconds: 0, fallbacks: [])
                    var fetch = "?"
                    do {
                        let dl = try await QTNativeStreamDownloader.download(stream)
                        fetch = "downloaded \(dl.bytes / 1024) KB in \(ms(dl.totalSeconds))"
                        try? FileManager.default.removeItem(at: dl.file)
                    } catch { fetch = "download \(error)" }
                    out("\(client.name) \(id) \(r.signedIn ? "auth" : "anon") itags [\(itags)] best \(f.itag) sig \(ms(s1 - s0)) n \(ms(s2 - s1)) → \(fetch)")
                } catch {
                    out("\(client.name) \(id) error \(error)")
                }
            }
        }
        out("solver: first solve (player AST preprocessing) \(ms(script.preprocessSeconds)); later solves reuse the preprocessed player")
    }

    // MARK: avplayer

    func avplayer() async throws {
        try await QTNativeSolverSource.ensureDownloaded()
        let creds = try await credentials(options.signedIn)
        let resolver = QTNativeStreamResolver(credentials: creds)
        let client: QTNativeStreamClient = options.signedIn ? .webRemix : .tvSamsung
        var aac: [Double] = []
        for id in options.ids.prefix(options.count ?? 5) {
            let r = try await resolver.player(videoId: id, client: client)
            let wanted = [r.bestPlayableAudio, r.audioFormats.first { $0.itag == 251 }, r.audioFormats.first { $0.itag == 774 }]
            for f in wanted.compactMap({ $0 }) {
                let url = try await resolver.mediaURL(for: f)
                let p = await QTNativeAVPlayerProbe.probe(url: url, userAgent: client.userAgent)
                if f.isAVFoundationPlayable, let t = p.playingSeconds { aac.append(t) }
                out("\(id) \(client.name) itag \(f.itag) \(f.codec): playable \(p.isPlayable) ready \(ms(p.readySeconds)) playing \(ms(p.playingSeconds)) \(p.error ?? "")")
            }
        }
        out("AVQueuePlayer AAC (progressive HTTP) time-to-playing median \(ms(median(aac))) — excludes the player request")
    }
}

@main
struct QTNativeSpikeMain {
    static func main() async {
        let options = SpikeOptions(CommandLine.arguments)
        do {
            try await Spike(options: options).run()
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }
}
#else
@main
struct QTNativeSpikeMain {
    static func main() { print("QTNativeSpike is DEBUG-only") }
}
#endif
