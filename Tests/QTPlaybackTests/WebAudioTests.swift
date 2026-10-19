import Foundation
import JavaScriptCore
import Testing
@testable import QTPlayback

/// The web engine's spectrum tap (web-audio): the page script runs in JavaScriptCore against a fake MediaSource,
/// `<video>` and decoder, so container parsing, cluster indexing across split appends, decode planning and the FFT
/// are tested offline; the native side's batching and degradation are tested with a stub page.
@MainActor
@Suite struct WebAudioTests {
    /// Byte builders and fakes for the page script (no DOM in JavaScriptCore).
    static let harness = """
    var window = globalThis;
    var video = { paused: false, currentTime: 0 };
    var document = { getElementById: () => null, querySelector: () => video };
    var performance = { now: () => Date.now() };
    function MediaSource() { this.readyState = 'open'; }
    MediaSource.prototype.addEventListener = function (n, f) { (this.l = this.l || {})[n] = f; };
    MediaSource.prototype.close = function () { this.readyState = 'closed'; if (this.l && this.l.sourceclose) this.l.sourceclose(); };
    MediaSource.prototype.addSourceBuffer = function () { return { timestampOffset: 0, appendBuffer() {} }; };
    // Decodes to a 1 kHz sine at 24 kHz, as long as the clusters' span says.
    var decoded = 0;
    function OfflineAudioContext(c, l, rate) { this.rate = rate; }
    OfflineAudioContext.prototype.decodeAudioData = function (buf) {
      decoded++;
      const n = 24000 * 4, d = new Float32Array(n);
      for (let i = 0; i < n; i++) d[i] = 0.5 * Math.sin(2 * Math.PI * 1000 * i / 24000);
      return Promise.resolve({ length: n, numberOfChannels: 1, sampleRate: 24000, getChannelData: () => d });
    };
    const bytes = (...parts) => { const a = []; for (const p of parts) for (const x of p) a.push(x); return new Uint8Array(a); };
    const str = (s) => Array.from(s, (c) => c.charCodeAt(0));
    const be = (v, n) => { const a = []; for (let i = n - 1; i >= 0; i--) a.push(Math.floor(v / Math.pow(256, i)) % 256); return a; };
    // WebM: EBML header, Segment (unknown size), Info (TimestampScale 1 ms), Tracks; clusters with a Timecode (ms).
    const webmInit = bytes([0x1A, 0x45, 0xDF, 0xA3, 0x87, 0x42, 0x82, 0x84], str('webm'), [0x42, 0x87, 0x81, 0x04],
                           [0x18, 0x53, 0x80, 0x67, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
                           [0x15, 0x49, 0xA9, 0x66, 0x87, 0x2A, 0xD7, 0xB1, 0x83, 0x0F, 0x42, 0x40], [0x16, 0x54, 0xAE, 0x6B, 0x80]);
    const cluster = (ms) => bytes([0x1F, 0x43, 0xB6, 0x75, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xE7, 0x82], be(ms, 2),
                                  [0xA3, 0x88, 0x81, 0x00, 0x00, 0x80, 1, 2, 3, 4]);
    // MP4: ftyp + moov/trak/mdia/mdhd (timescale), and moof/traf/tfdt (v1) + mdat fragments.
    const box = (type, ...payload) => { const p = bytes(...payload); return bytes(be(p.length + 8, 4), str(type), p); };
    const mp4Init = (timescale) => bytes(box('ftyp', str('dash'), be(0, 4)),
      box('moov', box('trak', box('mdia', box('mdhd', [0, 0, 0, 0], be(0, 4), be(0, 4), be(timescale, 4), be(0, 4), [0x55, 0xC4, 0, 0])))));
    const fragment = (ticks) => bytes(box('moof', box('mfhd', be(0, 4), be(1, 4)), box('traf', box('tfhd', be(0, 4), be(1, 4)),
                                      box('tfdt', [1, 0, 0, 0], be(ticks, 8)))), box('mdat', [9, 9, 9, 9]));
    """

    private func context() throws -> JSContext {
        let js = try #require(JSContext())
        js.exceptionHandler = { _, e in Issue.record("JS: \(e?.toString() ?? "?")") }
        js.evaluateScript(Self.harness)
        js.evaluateScript(QTWebAudioScript.parsers)
        js.evaluateScript(QTWebAudioScript.tap)
        return js
    }

    private func eval(_ js: JSContext, _ source: String) -> JSValue {
        js.evaluateScript(source)
    }

    @Test func parsersReadWebMAndMP4() throws {
        let js = try context()
        #expect(eval(js, "__qtAudioParse.kind(webmInit)").toString() == "webm")
        #expect(eval(js, "__qtAudioParse.kind(mp4Init(48000))").toString() == "mp4")
        #expect(eval(js, "__qtAudioParse.kind(cluster(0))").toString() == "")
        #expect(eval(js, "__qtAudioParse.webmScale(webmInit)").toInt32() == 1_000_000)
        // An init and its first cluster in one append split where the cluster starts.
        #expect(eval(js, "__qtAudioParse.mediaOffset(bytes(webmInit, cluster(0))) === webmInit.length").toBool())
        #expect(eval(js, "__qtAudioParse.mediaOffset(webmInit) === webmInit.length").toBool())
        #expect(eval(js, "__qtAudioParse.mediaOffset(cluster(2000))").toInt32() == 0)
        let clusters = eval(js, "JSON.stringify(__qtAudioParse.webmClusters(bytes(cluster(2000), cluster(4500)), 0))").toString()
        #expect(clusters == #"[{"at":0,"ticks":2000},{"at":26,"ticks":4500}]"#)

        #expect(eval(js, "__qtAudioParse.mp4Timescale(mp4Init(48000))").toInt32() == 48000)
        #expect(eval(js, "__qtAudioParse.mediaOffset(bytes(mp4Init(48000), fragment(0))) === mp4Init(48000).length").toBool())
        let fragments = eval(js, "JSON.stringify(__qtAudioParse.mp4Fragments(bytes(fragment(96000), fragment(192000)), 0).map(f => f.ticks))")
        #expect(fragments.toString() == "[96000,192000]")

        #expect(!eval(js, "__qtAudioParse.isProtected(webmInit) || __qtAudioParse.isProtected(mp4Init(48000))").toBool())
        #expect(eval(js, "__qtAudioParse.isProtected(bytes(mp4Init(48000), box('pssh', be(0, 4))))").toBool())
        #expect(eval(js, "__qtAudioParse.isProtected(bytes(webmInit, [0x47, 0xE2, 0x90]))").toBool())

        let edges = eval(js, "JSON.stringify(__qtAudioParse.bandEdges(48, 2048, 24000, 40, 12000))").toString() ?? ""
        let values = try JSONDecoder().decode([Int].self, from: Data(edges.utf8))
        #expect(values.count == 49 && values.first == 3 && values.last == 1023)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
    }

    /// Appends sliced anywhere (here: through a cluster header) are indexed by container time; frames come only
    /// for decoded windows, ahead of the playhead, and track the stream's spectrum.
    @Test func tapIndexesSplitAppendsAndReturnsSpectraAhead() throws {
        let js = try context()
        eval(js, """
        var ms = new MediaSource(), sb = ms.addSourceBuffer('audio/webm; codecs="opus"');
        sb.appendBuffer(webmInit);
        const media = bytes(cluster(0), cluster(2000), cluster(4000), cluster(6000), cluster(8000));
        sb.appendBuffer(media.subarray(0, 30)); sb.appendBuffer(media.subarray(30));
        video.currentTime = 1.0;
        """)
        let info = eval(js, "JSON.stringify(__qtAudio.info().tracks.map(t => [t.kind, t.marks, t.first, t.last]))").toString()
        #expect(info == #"[["webm",5,0,8]]"#)
        // First pull starts the decode (the fake resolves after this evaluation), the next one has spectra.
        #expect(eval(js, "__qtAudio.frames(48, 3, 1 / 60)").toString() == "pending")
        let frames = eval(js, "JSON.stringify(__qtAudio.frames(48, 3, 1 / 60))").toString() ?? ""
        let batch = try JSONDecoder().decode([[Double]].self, from: Data(frames.utf8))
        #expect(batch.count == 3 && batch.allSatisfy { $0.count == 48 })
        // 1 kHz sine: the loudest band is the one holding 1 kHz (log-spaced 40 Hz–12 kHz → band ~27).
        let loudest = try #require(batch[0].indices.max { batch[0][$0] < batch[0][$1] })
        #expect((25...29).contains(loudest), "loudest band \(loudest)")
        #expect(batch[0][loudest] > 0.8 && batch[0][0] < 0.2)
        #expect(eval(js, "decoded").toInt32() == 1)

        eval(js, "video.paused = true")
        #expect(eval(js, "__qtAudio.frames(48, 3, 1 / 60)").toString() == "paused")
        eval(js, "video.paused = false; __qtAudio.release()")
        #expect(eval(js, "__qtAudio.info().on").toBool() == false)
        #expect(eval(js, "__qtAudio.info().tracks[0].windows.length").toInt32() == 0)
    }

    /// With no visualizer on screen the tap keeps only what is still to play (plus a few seconds), so a long listening
    /// session doesn't pile up every song's audio; a first pull still decodes at the playhead.
    @Test func idleTapDropsPlayedAudioButStillServesThePlayhead() throws {
        let js = try context()
        eval(js, """
        var ms = new MediaSource(), sb = ms.addSourceBuffer('audio/webm; codecs="opus"');
        sb.appendBuffer(webmInit);
        sb.appendBuffer(bytes(cluster(0), cluster(2000), cluster(4000)));
        video.currentTime = 9.0;
        sb.appendBuffer(bytes(cluster(6000), cluster(8000), cluster(10000)));
        """)
        // 0–6 s played more than 3 s ago: its copy is gone; 6 s onwards stays.
        #expect(eval(js, "JSON.stringify(__qtAudio.info().tracks.map(t => [t.first, t.last, t.bytes, t.appended]))").toString()
                == "[[6,10,78,156]]")
        #expect(eval(js, "__qtAudio.info().stats.dropped").toInt32() == 78)
        #expect(eval(js, "__qtAudio.frames(48, 1, 1 / 60)").toString() == "pending")
        #expect(eval(js, "Array.isArray(__qtAudio.frames(48, 1, 1 / 60))").toBool(), "the playhead's cluster decodes")

        // While a visualizer asks, played audio stays (seeking back stays instant).
        eval(js, "video.currentTime = 30; sb.appendBuffer(bytes(cluster(12000), cluster(14000)))")
        #expect(eval(js, "__qtAudio.info().tracks[0].first").toInt32() == 6)
        // Once it is released, the copy shrinks to what is still to play.
        eval(js, "__qtAudio.release()")
        #expect(eval(js, "__qtAudio.info().tracks[0].first").toInt32() == 12)
    }

    /// A track's copies go when its MediaSource closes (next song, reload), and only a couple of open tracks are kept.
    @Test func tapForgetsClosedTracksAndKeepsFewOpenOnes() throws {
        let js = try context()
        eval(js, """
        var add = () => { const m = new MediaSource(), b = m.addSourceBuffer('audio/webm; codecs="opus"');
                          b.appendBuffer(bytes(webmInit, cluster(0), cluster(2000))); return m; };
        var first = add();
        first.close();
        """)
        #expect(eval(js, "__qtAudio.info().tracks.length").toInt32() == 0)
        eval(js, "add(); add(); add(); add()")
        #expect(eval(js, "__qtAudio.info().tracks.length").toInt32() == 2)
    }

    @Test func tapReportsMissingAndProtectedMedia() throws {
        let js = try context()
        #expect(eval(js, "__qtAudio.frames(48, 1, 1 / 60)").toString() == "nodata")
        eval(js, """
        var ms = new MediaSource(), sb = ms.addSourceBuffer('audio/mp4; codecs="mp4a.40.2"');
        sb.appendBuffer(bytes(mp4Init(44100), box('pssh', be(0, 4))));
        sb.appendBuffer(bytes(fragment(0), fragment(88200)));
        video.currentTime = 0.5;
        """)
        #expect(eval(js, "__qtAudio.frames(48, 1, 1 / 60)").toString() == "protected")
        // Video SourceBuffers are never touched.
        eval(js, "var vsb = new MediaSource().addSourceBuffer('video/webm; codecs=\"vp9\"'); vsb.appendBuffer(webmInit)")
        #expect(eval(js, "__qtAudio.info().tracks.length").toInt32() == 1)
    }

    /// The page side never builds a realtime Web Audio graph (it can't render in the WebContent process) and
    /// never touches the media element's output.
    @Test func tapNeverRoutesTheMediaElement() {
        let js = QTWebAudioScript.parsers + QTWebAudioScript.tap
        #expect(!js.contains("createMediaElementSource") && !js.contains("new AudioContext"))
        #expect(js.contains("OfflineAudioContext") && js.contains("addSourceBuffer"))
        #expect(!js.contains("setInterval(") && !js.contains("setTimeout("), "no page timers: the app pulls")
        let lines = js.split(separator: "\n").count
        #expect(lines < 290, "\(lines) lines")
    }

    // MARK: Native side

    @Test func resamplingKeepsPeaksAndInterpolates() {
        #expect(QTWebAudioTap.resample([0, 1, 0, 0.5], to: 2) == [1, 0.5])
        #expect(QTWebAudioTap.resample([0, 1], to: 2) == [0, 1])
        let up = QTWebAudioTap.resample([0, 1], to: 4)
        #expect(up.count == 4 && up.first == 0 && up.last == 1 && up == up.sorted())
        #expect(QTWebAudioTap.resample([], to: 3).isEmpty)
    }

    /// A batch is anchored at its round trip; each call reads the frame for its own uptime.
    @Test func batchFramesFollowTheClock() {
        let tap = QTWebAudioTap()
        let frames: [Any] = (0..<10).map { i in (0..<48).map { _ in NSNumber(value: Double(i) / 10) } }
        tap.apply(frames, anchor: 100)
        #expect(tap.status == .ok)
        #expect(tap.frame(at: 100)?.first == 0)
        #expect(tap.frame(at: 100 + 5 * QTWebAudioTap.frameStep)?.first == 0.5)
        #expect(tap.frame(at: 99.9)?.first == 0)                     // before the anchor: the first frame
        #expect(tap.frame(at: 100.3)?.first == 0.9)                  // just past the batch: hold the last
        #expect(tap.frame(at: 101.5) == nil)                         // stale
        tap.apply("pending", anchor: 101)
        #expect(tap.frame(at: 100.1) != nil, "a pending pull keeps the last batch")
        tap.apply("nodata", anchor: 101)
        #expect(tap.frame(at: 100.1) == nil)
    }

    @Test func spectrumPullsAndDegradesQuietly() async throws {
        let tap = QTWebAudioTap()
        var pulls = 0, released = 0
        var answer: Any? = (0..<10).map { _ in (0..<48).map { NSNumber(value: Double($0) / 48) } }
        tap.fetchFrames = { bands, ahead, step in
            pulls += 1
            #expect(bands == QTWebAudioTap.pageBandCount && ahead == QTWebAudioTap.framesAhead && step == QTWebAudioTap.frameStep)
            return answer
        }
        tap.releasePage = { released += 1 }
        // No data yet: zeros (the visualizer's resting shape), and one pull goes out.
        #expect(tap.spectrum(bandCount: 96) == Array(repeating: 0, count: 96))
        #expect(tap.spectrum(bandCount: 96) == Array(repeating: 0, count: 96))
        try await Task.sleep(for: .milliseconds(30))
        #expect(pulls == 1 && tap.isActive)
        let bands = try #require(tap.spectrum(bandCount: 96))
        #expect(bands.count == 96 && bands.last! > bands.first!)

        // Encrypted media: nil, so the visualizer animates on its own.
        answer = "protected"
        try await Task.sleep(for: .milliseconds(120))
        _ = tap.spectrum(bandCount: 96)
        try await Task.sleep(for: .milliseconds(30))
        #expect(tap.status == .protected && tap.spectrum(bandCount: 96) == nil)

        // Nobody asks: the page drops its decoded audio.
        try await Task.sleep(for: .seconds(1.5))
        #expect(released == 1 && !tap.isActive && tap.status == .idle)
    }
}
