import Foundation

/// The page side of the web engine's audio tap (`QTWebAudioTap`): spectrum data for the Stage visualizer from
/// YouTube Music's own player, without touching what plays.
///
/// Why not a Web Audio graph on the `<video>`: the engine runs media in the WebContent process (one Now Playing
/// entry, see `QTWebKitTuning`), and there a realtime `AudioContext` never renders (`currentTime` stays 0) —
/// WebKit renders Web Audio only in the GPU process. Even with GPU-process media, a `MediaElementAudioSourceNode`
/// on YouTube's MediaSource-fed `<video>` yields only silence in WebKit (measured on macOS 27: zeros at element
/// volume 0, 1 and muted), and GPU-process media brings back WebKit's own Now Playing entry. `docs/web-audio.md`.
///
/// What it does instead: YouTube's player feeds the `<video>` through MSE. The script keeps a copy of the audio
/// bytes the page appends (`SourceBuffer.appendBuffer`) and indexes where each WebM cluster / MP4 fragment starts
/// and at which media time (container timestamps + `timestampOffset`), so it doesn't matter how the page slices
/// its appends. The app *pulls* spectra (`__qtAudio.frames(bands, ahead, dt)`) only while a visualizer is on screen
/// and playing — no page timer runs (a hidden page's timers are throttled anyway). The first pull decodes the few
/// seconds under the playhead (`decodeAudioData` on an `OfflineAudioContext`, which does work in the WebContent
/// process). Since those samples are already there, each pull returns the FFTs for the playhead *and the next
/// display frames* (0…1, low → high, log-spaced 40 Hz–12 kHz), so ~10 pulls a second drive a 60 fps visualizer;
/// or it says why there are none (`paused`, `pending`, `nodata`, `protected`, `undecodable`).
/// `release()` drops the decoded audio once nobody asks. Otherwise the script only keeps copies of what is still
/// to play: while no visualizer asks, bytes more than a few seconds behind the playhead are dropped at every append
/// (and at `release()`), a track's copies go as soon as its MediaSource closes (the next song, a reload), and at most
/// `KEEP_TRACKS` open tracks are watched — so a hidden visualizer holds about the page's own read-ahead (< 1 MB measured),
/// not every song's audio. While a visualizer asks, a track keeps up to `KEEP_BYTES` (seeking back stays instant).
///
/// Decoded from the stream itself, the spectrum sits before every gain stage: the element's volume and mute (and
/// the engine's silent test mode) don't affect it. Encrypted (EME) or undecodable media make the app's visualizer
/// fall back to its own animation.
enum QTWebAudioScript {
    /// Container parsing (pure functions on `Uint8Array`s), on `window.__qtAudioParse`; unit-tested in JavaScriptCore.
    static let parsers = """
    (() => {
      if (window.__qtAudioParse) return;
      const uint = (b, o, n) => { let v = 0; for (let i = 0; i < n; i++) v = v * 256 + b[o + i]; return v; };
      // EBML variable-length integer at o: [value, length], or null.
      function vint(b, o) {
        const first = b[o]; if (first === undefined || first === 0) return null;
        let len = 1, mask = 0x80; while (!(first & mask)) { len++; mask >>= 1; }
        if (o + len > b.length) return null;
        let v = first & (mask - 1); for (let i = 1; i < len; i++) v = v * 256 + b[o + i];
        return [v, len];
      }
      const fourcc = (b, o) => String.fromCharCode(b[o], b[o + 1], b[o + 2], b[o + 3]);
      // 'webm' | 'mp4' | '' from an init segment's first bytes.
      function kind(b) {
        if (b.length >= 4 && b[0] === 0x1A && b[1] === 0x45 && b[2] === 0xDF && b[3] === 0xA3) return 'webm';
        if (b.length >= 8 && (fourcc(b, 4) === 'ftyp' || fourcc(b, 4) === 'moov')) return 'mp4';
        return '';
      }
      // Where the media part of an append starts: 0 = all media, b.length = all init.
      function mediaOffset(b) {
        const k = kind(b);
        if (k === 'webm') { const c = webmClusters(b, 0); return c.length ? c[0].at : b.length; }
        if (k === 'mp4') {
          for (let o = 0; o + 8 <= b.length;) {
            const t = fourcc(b, o + 4); if (t === 'moof' || t === 'styp' || t === 'sidx' || t === 'emsg') return o;
            const size = uint(b, o, 4); if (size < 8) return b.length; o += size;
          }
          return b.length;
        }
        return 0;
      }
      // WebM TimestampScale (ns per tick; default 1 ms).
      function webmScale(init) {
        for (let o = 0; o + 4 < init.length; o++) {
          if (init[o] !== 0x2A || init[o + 1] !== 0xD7 || init[o + 2] !== 0xB1) continue;
          const s = vint(init, o + 3); if (s && s[0] >= 1 && s[0] <= 8) return uint(init, o + 3 + s[1], s[0]);
        }
        return 1e6;
      }
      // WebM clusters in b: [{at, ticks}] (Cluster ID, size, then its Timecode element).
      function webmClusters(b, from) {
        const out = [];
        for (let o = from; o + 4 <= b.length; o++) {
          if (b[o] !== 0x1F || b[o + 1] !== 0x43 || b[o + 2] !== 0xB6 || b[o + 3] !== 0x75) continue;
          const size = vint(b, o + 4); if (!size) continue;
          const c = o + 4 + size[1]; if (b[c] !== 0xE7) continue;
          const n = vint(b, c + 1); if (!n || n[0] < 1 || n[0] > 8 || c + 1 + n[1] + n[0] > b.length) continue;
          out.push({ at: o, ticks: uint(b, c + 1 + n[1], n[0]) });
        }
        return out;
      }
      function find(b, type, from, to) {
        const c0 = type.charCodeAt(0);
        for (let o = from; o + 8 <= to; o++) if (b[o + 4] === c0 && fourcc(b, o + 4) === type) return o;
        return -1;
      }
      // MP4 media timescale (mdhd).
      function mp4Timescale(init) {
        const o = find(init, 'mdhd', 0, init.length); if (o < 0) return 0;
        return uint(init, o + 8 + (init[o + 8] === 1 ? 20 : 12), 4);
      }
      // MP4 fragments in b: [{at, ticks}] (moof → traf → tfdt baseMediaDecodeTime).
      function mp4Fragments(b, from) {
        const out = [];
        for (let o = from; o + 8 <= b.length; o++) {
          if (b[o + 4] !== 0x6D || fourcc(b, o + 4) !== 'moof') continue;
          const size = uint(b, o, 4); if (size < 16) continue;
          const t = find(b, 'tfdt', o + 8, Math.min(b.length, o + size)); if (t < 0 || t + 20 > b.length) continue;
          out.push({ at: o, ticks: b[t + 8] === 1 ? uint(b, t + 12, 8) : uint(b, t + 12, 4) });
        }
        return out;
      }
      // Encrypted media (CENC boxes / WebM ContentEncKeyID).
      function isProtected(init) {
        for (const t of ['encv', 'enca', 'pssh', 'tenc']) if (find(init, t, 0, init.length) >= 0) return true;
        // WebM ContentEncKeyID (0x47E2) with its 16-byte key id.
        for (let o = 0; o + 2 < init.length; o++) if (init[o] === 0x47 && init[o + 1] === 0xE2 && init[o + 2] === 0x90) return true;
        return false;
      }
      // Band edges (FFT bins) for `count` log-spaced bands, lo…hi Hz.
      function bandEdges(count, n, rate, lo, hi) {
        const a = Math.log(lo), z = Math.log(hi), e = [];
        for (let i = 0; i <= count; i++) e.push(Math.max(1, Math.min(n / 2 - 1, Math.round(Math.exp(a + (z - a) * i / count) / (rate / n)))));
        return e;
      }
      window.__qtAudioParse = { vint, kind, mediaOffset, webmScale, webmClusters, mp4Timescale, mp4Fragments, isProtected, bandEdges };
    })();
    """

    /// Page world, document start, after `parsers` and before the bridge (so it sees YouTube's first SourceBuffer).
    static let tap = """
    (() => {
      if (window.__qtAudio || !window.MediaSource || !window.__qtAudioParse) return;
      const X = window.__qtAudioParse;
      // KEEP_BYTES: per track while a visualizer asks. Idle, only what is still to play (minus BEHIND s) is kept.
      const KEEP_BYTES = 12 << 20, KEEP_TRACKS = 2, BEHIND = 3, RATE = 24000, N = 2048, WINDOW = 6;
      const A = { tracks: [], on: false, lastAsk: 0, ctx: null, state: '', edges: null,
                  stats: { appends: 0, marks: 0, decodes: 0, failures: 0, decodeMs: 0, frames: 0, frameMs: 0, dropped: 0 } };
      const view = (d) => d instanceof ArrayBuffer ? new Uint8Array(d) : new Uint8Array(d.buffer, d.byteOffset, d.byteLength);
      const video = () => { const p = document.getElementById('movie_player'); return (p && p.querySelector('video')) || document.querySelector('video'); };

      // One audio SourceBuffer: its bytes as one stream (chunks at absolute offsets) and the cluster/fragment marks.
      function watch(sb, mime, ms) {
        const T = { sb, mime, ms, init: null, kind: '', scale: 0, chunks: [], size: 0, tail: new Uint8Array(0), lastAt: -1,
                    marks: [], windows: [], protected: false };
        // A closed MediaSource (the next song, a reload) never plays again: forget it and its copies at once.
        const forget = () => { const i = A.tracks.indexOf(T); if (i >= 0) A.tracks.splice(i, 1); T.chunks = []; T.marks = []; T.windows = []; };
        try { ms.addEventListener('sourceclose', forget, { once: true }); } catch (_) {}
        A.tracks = A.tracks.filter((x) => x.ms.readyState !== 'closed');
        A.tracks.push(T); while (A.tracks.length > KEEP_TRACKS) A.tracks.shift();
        const append = sb.appendBuffer;
        sb.appendBuffer = function (data) {
          try { ingest(T, view(data)); } catch (_) {}
          return append.apply(this, arguments);
        };
      }
      function ingest(T, b) {
        A.stats.appends++;
        const o = X.mediaOffset(b);
        if (o > 0) {
          T.init = b.slice(0, o); T.kind = X.kind(T.init); T.protected = X.isProtected(T.init);
          T.scale = T.kind === 'webm' ? X.webmScale(T.init) / 1e9 : (1 / (X.mp4Timescale(T.init) || 1));
        }
        if (o >= b.length || !T.init) return;
        const chunk = b.slice(o), off = T.size;
        T.chunks.push({ off, bytes: chunk }); T.size += chunk.length;
        // Scan with the previous chunk's tail so headers split across appends are found too.
        const scan = new Uint8Array(T.tail.length + chunk.length); scan.set(T.tail, 0); scan.set(chunk, T.tail.length);
        const base = off - T.tail.length, tso = T.sb.timestampOffset || 0;
        const found = T.kind === 'webm' ? X.webmClusters(scan, 0) : X.mp4Fragments(scan, 0);
        for (const m of found) {
          const at = base + m.at; if (at <= T.lastAt) continue;
          T.lastAt = at; T.marks.push({ at, time: m.ticks * T.scale + tso, init: T.init }); A.stats.marks++;
        }
        T.tail = scan.slice(Math.max(0, scan.length - 64));
        trim(T);
      }
      // Drops copies nobody will decode: over KEEP_BYTES (oldest first) and, while no visualizer asks, what played
      // more than BEHIND s ago — the leading run of marks (in append order) behind the playhead. A first pull then
      // still finds the playhead's cluster and everything the page has read ahead.
      function trim(T) {
        if (!T.chunks.length) return;
        let cut = T.chunks[0].off;
        const v = A.on ? null : video();
        if (v && T.ms.readyState !== 'closed') {
          const t = v.currentTime - BEHIND;
          for (let i = 0; i + 1 < T.marks.length && T.marks[i + 1].time <= t && T.marks[i].time <= t; i++) cut = T.marks[i + 1].at;
        }
        let bytes = T.size - T.chunks[0].off;
        while (T.chunks.length > 1 && (T.chunks[0].off + T.chunks[0].bytes.length <= cut || bytes > KEEP_BYTES)) {
          const c = T.chunks.shift(); bytes -= c.bytes.length; A.stats.dropped += c.bytes.length;
        }
        const first = T.chunks[0].off; while (T.marks.length && T.marks[0].at < first) T.marks.shift();
      }
      const addSourceBuffer = MediaSource.prototype.addSourceBuffer;
      MediaSource.prototype.addSourceBuffer = function (mime) {
        const sb = addSourceBuffer.apply(this, arguments);
        try { if (/^audio\\//i.test(String(mime))) watch(sb, String(mime), this); } catch (_) {}
        return sb;
      };
      function bytes(T, a, z) {
        if (!T.chunks.length || a < T.chunks[0].off || z > T.size || z <= a) return null;
        const out = new Uint8Array(z - a);
        for (const c of T.chunks) {
          const s = Math.max(a, c.off), e = Math.min(z, c.off + c.bytes.length);
          if (e > s) out.set(c.bytes.subarray(s - c.off, e - c.off), s - a);
        }
        return out;
      }
      // The marks to decode for time t: from the latest-appended mark at or before t, ~WINDOW s of whole clusters.
      function plan(T, t) {
        const M = T.marks, ok = (p, q) => q.time > p.time && q.time - p.time < 30 && q.init === p.init;
        for (let i = M.length - 1; i >= 0; i--) {
          const a = M[i];
          if (a.time > t + 0.01) continue;
          if (i + 1 < M.length) {
            if (!ok(a, M[i + 1]) || M[i + 1].time <= t) continue;
            let j = i + 1; while (j + 1 < M.length && ok(M[j], M[j + 1]) && M[j].time - a.time < WINDOW) j++;
            return { a, z: M[j].at, key: a.at + ':' + M[j].at };
          }
          // The last cluster of a finished stream decodes to the end of the bytes.
          if (T.ms.readyState === 'ended') return { a, z: T.size, key: a.at + ':end' };
          return null;
        }
        return null;
      }
      function decode(T, p) {
        if (T.windows.some((w) => w.key === p.key)) return;
        const media = bytes(T, p.a.at, p.z); if (!media) return;
        if (!A.ctx) { try { A.ctx = new OfflineAudioContext(1, 1, RATE); } catch (_) { return; } }
        const w = { key: p.key, start: p.a.time, end: p.a.time, pcm: null, rate: RATE, failed: false };
        T.windows.push(w); if (T.windows.length > 3) T.windows.shift();
        const all = new Uint8Array(p.a.init.length + media.length); all.set(p.a.init, 0); all.set(media, p.a.init.length);
        const t0 = performance.now();
        A.ctx.decodeAudioData(all.buffer).then((buf) => {
          const n = buf.length, mono = new Float32Array(n), k = 1 / buf.numberOfChannels;
          for (let c = 0; c < buf.numberOfChannels; c++) { const d = buf.getChannelData(c); for (let i = 0; i < n; i++) mono[i] += d[i] * k; }
          w.pcm = mono; w.rate = buf.sampleRate; w.end = w.start + n / buf.sampleRate;
          A.stats.decodes++; A.stats.decodeMs += Math.round(performance.now() - t0);
        }, () => { w.failed = true; A.stats.failures++; });
      }
      function report(state, mime) { A.state = state; A.mime = mime || A.mime; return state; }
      // The audio track feeding the element now: an open MediaSource with a mark at or before the playhead.
      function current(t) {
        for (let i = A.tracks.length - 1; i >= 0; i--) {
          const T = A.tracks[i];
          if (T.ms.readyState !== 'closed' && T.init && T.marks.some((m) => m.time <= t + 0.01)) return T;
        }
        return null;
      }

      const W = new Float32Array(N); for (let i = 0; i < N; i++) W[i] = 0.5 - 0.5 * Math.cos(2 * Math.PI * i / (N - 1));
      const re = new Float32Array(N), im = new Float32Array(N), mag = new Float32Array(N / 2);
      const bits = Math.log2(N), rev = new Uint32Array(N);
      for (let i = 0; i < N; i++) { let r = 0; for (let b = 0; b < bits; b++) r |= ((i >> b) & 1) << (bits - 1 - b); rev[i] = r; }
      const cos = new Float32Array(N / 2), sin = new Float32Array(N / 2);
      for (let i = 0; i < N / 2; i++) { cos[i] = Math.cos(-2 * Math.PI * i / N); sin[i] = Math.sin(-2 * Math.PI * i / N); }
      function fft() {
        for (let i = 0; i < N; i++) { const j = rev[i]; if (j > i) { let t = re[i]; re[i] = re[j]; re[j] = t; t = im[i]; im[i] = im[j]; im[j] = t; } }
        for (let size = 2; size <= N; size <<= 1) {
          const h = size >> 1, step = N / size;
          for (let i = 0; i < N; i += size) for (let j = 0; j < h; j++) {
            const wr = cos[j * step], wi = sin[j * step], a = i + j, b = a + h;
            const tr = re[b] * wr - im[b] * wi, ti = re[b] * wi + im[b] * wr;
            re[b] = re[a] - tr; im[b] = im[a] - ti; re[a] += tr; im[a] += ti;
          }
        }
      }
      // The spectrum of the N samples before media time t in decoded window w → out (count bands).
      function spectrumAt(w, t, count) {
        const end = Math.round((t - w.start) * w.rate);
        for (let i = 0; i < N; i++) { const j = end - N + i; re[i] = (j >= 0 && j < w.pcm.length ? w.pcm[j] : 0) * W[i]; im[i] = 0; }
        fft();
        for (let i = 0; i < N / 2; i++) mag[i] = Math.hypot(re[i], im[i]) * 4 / N;
        if (!A.edges || A.edges.length !== count + 1) A.edges = X.bandEdges(count, N, RATE, 40, 12000);
        const out = new Array(count);
        for (let k = 0; k < count; k++) {
          let m = 0; for (let i = A.edges[k], e = Math.max(A.edges[k], A.edges[k + 1] - 1); i <= e; i++) m = Math.max(m, mag[i]);
          // dB with a gentle +3 dB/octave tilt (music falls off towards treble), mapped -66…-6 dB → 0…1.
          const db = 20 * Math.log10(m + 1e-9) + 3 * Math.log2((A.edges[k] + 1) * (RATE / N) / 400);
          out[k] = Math.round(Math.min(1, Math.max(0, (db + 66) / 60)) * 1000) / 1000;
        }
        return out;
      }
      // Spectra for the playhead and the `ahead` frames after it, `dt` s apart (the samples are already decoded, so
      // one pull covers several display frames): an array of band arrays, or the reason there are none.
      function frames(bands, ahead, dt) {
        A.on = true;
        const f0 = performance.now();
        const v = video(); if (!v) return 'nodata';
        if (v.paused) return 'paused';
        const t = v.currentTime, T = current(t);
        if (!T) return report('nodata');
        if (T.protected) return report('protected', T.mime);
        const at = (x) => T.windows.find((w) => w.pcm && x >= w.start && x < w.end);
        const w = at(t);
        if (!w) {
          const p = plan(T, t); if (p) decode(T, p);
          const pending = p && T.windows.find((x) => x.key === p.key);
          return pending && pending.failed ? report('undecodable', T.mime) : 'pending';
        }
        if (w.end - t < 2) { const p = plan(T, w.end); if (p) decode(T, p); }
        const count = Math.max(4, Math.min(256, bands | 0 || 48)), out = [];
        for (let k = 0, n = Math.max(1, Math.min(30, ahead | 0 || 1)); k < n; k++) {
          const tk = t + k * (dt || 1 / 60), wk = at(tk); if (!wk) break;
          out.push(spectrumAt(wk, tk, count));
        }
        report('ok', T.mime);
        A.stats.frames += out.length; A.stats.pulls = (A.stats.pulls || 0) + 1; A.stats.frameMs += performance.now() - f0;
        return out;
      }
      function release() { A.on = false; A.state = ''; for (const T of A.tracks) { T.windows = []; trim(T); } }
      window.__qtAudio = {
        // Pulled by the app (about ten times a second) only while a visualizer is on screen and playing.
        frames,
        // Nobody asks any more: decoded audio only lives while needed.
        release() { release(); return true; },
        info() {
          const v = video(), t = v ? v.currentTime : 0, T = current(t);
          return { on: A.on, state: A.state, mime: A.mime || '', stats: A.stats, t,
                   tracks: A.tracks.map((x) => ({ mime: x.mime, open: x.ms.readyState, kind: x.kind, protected: x.protected,
                     marks: x.marks.length, first: x.marks.length ? x.marks[0].time : null, last: x.marks.length ? x.marks[x.marks.length - 1].time : null,
                     bytes: x.size - (x.chunks.length ? x.chunks[0].off : 0), appended: x.size, windows: x.windows.map((w) => [w.start, w.end, !!w.pcm, w.failed]) })),
                   current: T ? T.mime : null };
        },
      };
    })();
    """
}
