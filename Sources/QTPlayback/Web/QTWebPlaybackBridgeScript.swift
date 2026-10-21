import Foundation

/// The whole JavaScript side of `QTWebPlaybackEngine`. Deliberately tiny (Kaset's ~6k-line bridge is the
/// anti-pattern): it only *reports* the player's state and *forwards* six commands. It never touches YouTube
/// Music's queue, never registers `navigator.mediaSession` handlers and never decides what plays next — the
/// app's `QTQueueController` does.
///
/// Messages (`window.webkit.messageHandlers.qtPlayback`):
/// - `{type:"ready"}` once the page's player API exists;
/// - `{type:"state", gen, vid, t, d, paused, ps, buffering, ad, vol, muted, vw, vh, rs, pip, rate, pic}` on media events
///   (≤ 2/s; `rate` = the media's playback rate, see `rate`; `pic` = bars still visible around the cropped picture,
///   left/top/right/bottom fractions of the slot);
/// - `{type:"ended", gen, vid}` exactly once per load generation when content (not an ad) finishes;
/// - `{type:"error", gen, vid, code, status, reason}` when the player reports an error or the item's
///   playability status isn't OK (age-restricted, region-locked, removed…);
/// - `{type:"pip", gen, playing}` (before the state it changes) when the listener plays or pauses from the Picture in
///   Picture window, or closes it (WebKit pauses then; `pictureInPicture`): its Play drops the bridge's hold — except at the item's end,
///   where YouTube's own autoplay stays held — and its pause becomes one, so neither side fights the other.
///
/// Power: while the app shows no video the bridge asks for the lowest video quality, so the hidden view decodes
/// 144p at most; and while paused the engine *freezes* the page's timers (`freeze()`), so YouTube Music's
/// polling, heartbeats and UI timers stop until the next command thaws them.
///
/// Video (M5, separate `videoSurface` script): the bridge's `present(on, quality)` turns the page into a bare video
/// surface — every element is hidden (`visibility`, so YouTube's own layout and logic keep running), each decoded
/// frame is drawn onto one full-viewport canvas (`object-fit: cover`, burned-in letterbox and pillarbox bars cropped), nothing
/// takes the pointer — and asks for a quality that fits the slot showing it. Frames go through a canvas because
/// WebKit's inline video layer stays blank (white) once the web view has moved out of the window it was created
/// in, while ordinary page content composites wherever the view goes; one `drawImage` per frame, only while
/// presented. While an ad plays the page draws as YouTube made it (the app covers it with its own ad state), so
/// the skip button stays reachable. `pip(on)` enters/leaves WebKit's native Picture in Picture.
enum QTWebPlaybackBridgeScript {
    /// Message handler name shared by the script and `QTWebPlaybackEngine`.
    static let handlerName = "qtPlayback"

    /// Injected at document start (page world): initial load parameters for the first document.
    static func bootstrap(generation: Int, videoID: String, hold: Bool, volume: Double, muted: Bool, silent: Bool,
                          lowQuality: Bool = true, present: Bool = false, quality: String = "tiny",
                          standby: Bool = false, rate: Double = 1) -> String {
        let payload: [String: Any] = [
            "gen": generation, "target": videoID, "hold": hold, "vol": volume, "muted": muted, "silent": silent,
            "lowQuality": lowQuality, "present": present, "quality": quality, "standby": standby, "rate": rate,
        ]
        let json = (try? JSONSerialization.data(withJSONObject: payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "window.__qtInit = \(json);"
    }

    /// Silences every media element at the source (volume pinned to 0, not `muted`: muted media is not
    /// Now Playing-eligible in WebKit, so tests stay honest about Now Playing ownership). Tests/lab only.
    static let silence = """
    (() => {
      const d = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'volume');
      Object.defineProperty(HTMLMediaElement.prototype, 'volume', { configurable: true,
        get() { return d.get.call(this); }, set(_) { d.set.call(this, 0); } });
      for (const ev of ['loadedmetadata', 'play', 'playing']) {
        document.addEventListener(ev, e => { try { d.set.call(e.target, 0); } catch (_) {} }, true);
      }
    })();
    """

    /// Keeps YouTube's page out of the system media session. Belt and braces: the engine also runs media in the
    /// WebContent process (no GPU-process Now Playing entry); this stops the page's own action handlers and
    /// metadata from ever reaching WebKit's media-session layer.
    static let mediaSessionShield = """
    (() => {
      const ms = navigator.mediaSession;
      if (!ms || ms.__qtShielded) return;
      try {
        ms.setActionHandler = function () {};
        Object.defineProperty(ms, 'metadata', { configurable: true, get() { return null; }, set(_) {} });
        Object.defineProperty(ms, 'playbackState', { configurable: true, get() { return 'none'; }, set(_) {} });
        ms.setPositionState = function () {};
        ms.__qtShielded = true;
      } catch (_) {}
    })();
    """

    /// The music video as a bare surface (page world, document start, before the bridge so it keeps the page's
    /// own timers): `window.__qtVideo.present(on)` hides everything but the video (`qt-present`), `tick` follows
    /// ads and element swaps. See the header for why frames go through a canvas.
    static let videoSurface = """
    (() => {
      if (window.__qtVideo) return;
      const raw = { st: setTimeout.bind(window) };
      const video = () => { const p = document.getElementById('movie_player'); return (p && p.querySelector('video')) || document.querySelector('video'); };
      // Bare video surface (see header). `qt-ad` lifts it while an ad plays.
      const VIDEO_CSS = `
        html.qt-present:not(.qt-ad), html.qt-present:not(.qt-ad) body { background: transparent !important; overflow: hidden !important; }
        html.qt-present:not(.qt-ad) * { visibility: hidden !important; pointer-events: none !important; cursor: default !important; }
        html.qt-present:not(.qt-ad) *:has(video) { transform: none !important; filter: none !important; contain: none !important;
          will-change: auto !important; perspective: none !important; opacity: 1 !important; clip-path: none !important; }
        html.qt-present:not(.qt-ad) video { visibility: visible !important; display: block !important; position: fixed !important;
          inset: 0 !important; left: 0 !important; top: 0 !important; width: 100vw !important; height: 100vh !important;
          max-width: none !important; max-height: none !important; margin: 0 !important; object-fit: cover !important;
          transform: none !important; opacity: 1 !important; z-index: 2147483646 !important; background: transparent !important; }
        #qt-video-canvas { display: none; }
        html.qt-present:not(.qt-ad) #qt-video-canvas { display: block; visibility: visible !important; position: fixed; inset: 0;
          width: 100vw; height: 100vh; object-fit: cover; z-index: 2147483647; pointer-events: none; background: #000; }`;
      // The frames themselves are copied onto a canvas (one draw per decoded frame, sized to the slot): WebKit's
      // inline video layer stays blank once the web view has moved out of the window it was created in, while
      // ordinary page content — a canvas — composites wherever the view goes.
      // Bars burned into the stream — letterbox (a 2.39:1 film in a 16:9 upload) and pillarbox (a 4:3 or square
      // picture, film-gate frames with sprocket notches) — are measured on a tiny probe and cropped away, so a slot
      // shows the real picture edge to edge. Quick probes while a video starts, then every couple of seconds; a crop
      // is only adopted when it repeats (a dark scene is not a bar) and changes glide over a few frames.
      const C = { canvas: null, ctx: null, running: false, v: null, handle: 0, probe: null, lastProbe: 0, probes: 0, src: '',
                  crop: [0, 0, 0, 0], target: [0, 0, 0, 0], raw: [0, 0, 0, 0], cand: null, seen: 0, srcAt: 0, pic: [0, 0, 0, 0],
                  min: null };
      const PW = 64, PH = 64, DARK = 24;
      // Per side: the share of the frame that is a burned-in bar (left, top, right, bottom), or null when unsure.
      function probeBars(v) {
        if (!C.probe) { C.probe = document.createElement('canvas'); C.probe.width = PW; C.probe.height = PH; }
        const p = C.probe.getContext('2d', { willReadFrequently: true });
        p.drawImage(v, 0, 0, PW, PH);
        const d = p.getImageData(0, 0, PW, PH).data;
        const dk = (x, y) => { const i = (y * PW + x) * 4; return d[i] < DARK && d[i + 1] < DARK && d[i + 2] < DARK; };
        const row = (y, x0, x1) => { let n = 0; for (let x = x0; x < x1; x++) if (dk(x, y)) n++; return n / Math.max(1, x1 - x0); };
        const col = (x, y0, y1) => { let n = 0; for (let y = y0; y < y1; y++) if (dk(x, y)) n++; return n / Math.max(1, y1 - y0); };
        // The middle must be lit: an all-dark frame (fade, night scene) says nothing about bars.
        let lit = 0;
        for (let y = PH * 0.3 | 0; y < PH * 0.7; y += 2) for (let x = PW * 0.3 | 0; x < PW * 0.7; x += 2) if (!dk(x, y)) lit++;
        if (lit < 12) return null;
        // Solid bars: whole rows / columns dark. Then step over the picture's soft edge (rounded film corners,
        // sprocket notches): lines that are still partly dark, at most 5 % more.
        const edge = (line, n, limit) => {
          let k = 0; while (k < limit && line(k) >= 0.96) k++;
          if (k === 0) return 0;
          let soft = 0; while (soft < n * 0.05 && k + soft < limit && line(k + soft) > 0.06) soft++;
          return k + soft + 1;   // + one probe line clears the blur of the boundary
        };
        // Side bars run the full height; top and bottom bars are then looked for between them only.
        let l = edge(i => col(i, 0, PH), PW, PW * 0.36 | 0), r = edge(i => col(PW - 1 - i, 0, PH), PW, PW * 0.36 | 0);
        // Bars come in pairs; a lone dark side is the scene.
        if (!(l > 1 && r > 1)) { l = 0; r = 0; }
        const x0 = Math.min(l, PW / 3 | 0), x1 = Math.max(x0 + 1, PW - Math.min(r, PW / 3 | 0));
        let t = edge(i => row(i, x0, x1), PH, PH * 0.3 | 0), b = edge(i => row(PH - 1 - i, x0, x1), PH, PH * 0.3 | 0);
        if (!(t > 1 && b > 1)) { t = 0; b = 0; }
        return [l / PW, t / PH, r / PW, b / PH];
      }
      function measureBars(v) {
        const now = Date.now();
        if (C.src !== v.currentSrc) {
          C.src = v.currentSrc; C.lastProbe = 0; C.probes = 0; C.cand = null; C.seen = 0; C.srcAt = now; C.min = null;
          C.raw = [0, 0, 0, 0]; C.target = [0, 0, 0, 0]; C.crop = [0, 0, 0, 0];
        }
        if (now - C.lastProbe < (C.probes < 12 ? 250 : 2000)) return;
        C.lastProbe = now; C.probes++;
        let m = null; try { m = probeBars(v); } catch (_) {}
        if (!m) return;
        // Burned-in bars never change within a video, scenes do: the crop is the smallest bar seen so far (a dark
        // opening scene that looked like bars lets go as soon as a brighter one shows), adopted once three probes
        // in a row agree.
        C.min = C.min ? C.min.map((x, i) => Math.min(x, m[i])) : m;
        const same = C.cand && m.every((x, i) => Math.abs(x - C.cand[i]) <= 0.02);
        C.cand = m; C.seen = same ? C.seen + 1 : 1;
        if (C.seen < 3 && C.target.every(x => x === 0)) return;
        m = C.min;
        C.raw = m;
        // Never crop past a square picture (vertical videos keep part of their bars) or a 2.4:1 film.
        C.target = [Math.min(0.22, m[0]), Math.min(0.2, m[1]), Math.min(0.22, m[2]), Math.min(0.2, m[3])];
      }
      // The crop glides to its target (snaps while the video is still starting), so a late correction never jumps.
      function stepCrop() {
        const snap = Date.now() - C.srcAt < 1500;
        C.crop = C.crop.map((x, i) => { const t = C.target[i]; return snap || Math.abs(t - x) < 0.002 ? t : x + (t - x) * 0.12; });
      }
      function frameTarget(sw, sh) {
        const dpr = window.devicePixelRatio || 2;
        const cover = Math.max(innerWidth * dpr / sw, innerHeight * dpr / sh);
        const k = Math.min(1, cover);   // never larger than the decoded frame
        return [Math.max(2, Math.round(sw * k)), Math.max(2, Math.round(sh * k))];
      }
      // Bars that are still visible after the crop (vertical videos), as fractions of the slot: the app keeps
      // overlays (the Stage's lyric line) over the picture.
      function visibleBars(vw, vh, sx, sy, sw, sh) {
        const W = innerWidth, H = innerHeight, s = Math.max(W / sw, H / sh), x0 = (W - sw * s) / 2, y0 = (H - sh * s) / 2;
        const f = (px, n) => Math.max(0, Math.min(0.45, px / n));
        return [f(x0 + (C.raw[0] * vw - sx) * s, W), f(y0 + (C.raw[1] * vh - sy) * s, H),
                f(x0 + (sx + sw - (1 - C.raw[2]) * vw) * s, W), f(y0 + (sy + sh - (1 - C.raw[3]) * vh) * s, H)]
               .map(x => Math.round(x * 1000) / 1000);
      }
      function drawFrame() {
        C.handle = 0;
        if (!C.running) return;
        drawOnce();
        scheduleFrame();
      }
      function drawOnce() {
        const v = video();
        if (v && v.videoWidth > 0 && v.readyState >= 2) {
          if (!C.canvas) {
            const c = document.createElement('canvas'); c.id = 'qt-video-canvas';
            document.documentElement.appendChild(c);
            C.canvas = c; C.ctx = c.getContext('2d', { alpha: false, desynchronized: true });
          }
          measureBars(v);
          stepCrop();
          const vw = v.videoWidth, vh = v.videoHeight, c = C.crop;
          const sx = Math.round(vw * c[0]), sy = Math.round(vh * c[1]);
          const sw = Math.max(2, vw - sx - Math.round(vw * c[2])), sh = Math.max(2, vh - sy - Math.round(vh * c[3]));
          const [w, h] = frameTarget(sw, sh);
          if (C.canvas.width !== w || C.canvas.height !== h) { C.canvas.width = w; C.canvas.height = h; }
          try { C.ctx.drawImage(v, sx, sy, sw, sh, 0, 0, w, h); } catch (_) {}
          C.pic = visibleBars(vw, vh, sx, sy, sw, sh);
        }
      }
      function scheduleFrame() {
        if (!C.running || C.handle) return;
        const v = video();
        if (v && v.requestVideoFrameCallback) { C.v = v; C.handle = v.requestVideoFrameCallback(drawFrame); }
        else C.handle = raw.st(drawFrame, 33);
      }
      function setFrames(on) {
        C.running = on;
        // Shown again (another slot, back from the hidden host): probe quickly and snap to what it finds.
        if (on) { C.probes = 0; C.lastProbe = 0; C.srcAt = Date.now(); }
        if (on) raw.st(() => { if (C.running) { drawOnce(); scheduleFrame(); } }, 0);
        else if (C.handle && C.v && C.v.cancelVideoFrameCallback) { C.v.cancelVideoFrameCallback(C.handle); C.handle = 0; }
      }
      window.addEventListener('resize', () => { if (C.running) drawOnce(); });
      document.addEventListener('seeked', () => { if (C.running) drawOnce(); }, true);
      function installVideoStyle() {
        if (document.getElementById('qt-video-style')) return;
        const el = document.createElement('style'); el.id = 'qt-video-style'; el.textContent = VIDEO_CSS;
        (document.head || document.documentElement).appendChild(el);
      }
      window.__qtVideo = {
        present(on) {
          installVideoStyle();
          document.documentElement.classList.toggle('qt-present', !!on);
          setFrames(!!on);
        },
        // Every bridge sample: ads lift the surface; a new <video> element needs a fresh frame callback.
        tick(ad, paused) {
          document.documentElement.classList.toggle('qt-ad', !!ad);
          const v = video();
          if (C.running && v && C.v !== v) { C.handle = 0; scheduleFrame(); }
          if (C.running && v && !paused && !C.handle) scheduleFrame();
        },
        info() { return { bars: C.raw, crop: C.crop.map(x => Math.round(x * 1000) / 1000), picture: C.pic,
                         canvas: C.canvas ? C.canvas.width + 'x' + C.canvas.height : '' }; },
        // Bars still visible around the picture (left, top, right, bottom; fractions of the slot), while presented.
        pictureBars() { return C.running ? C.pic : [0, 0, 0, 0]; },
      };
    })();
    """

    /// The Picture in Picture window's own Play / Pause are the listener's (page world, document start, before the
    /// bridge). WebKit plays and pauses the media itself from that window, so the bridge only sees media events; on
    /// each report it asks `__qtPip.tick(sample, hold, eligible)` — eligible: content of this load that has played
    /// and hasn't ended. 'play': the media plays in PiP while the bridge holds it (the app had paused) → the bridge
    /// drops the hold and thaws the page instead of re-pausing it. 'pause': the player paused (state 2) in PiP, or
    /// within 3 s of the listener closing the window (WebKit pauses then) → the bridge holds, so nothing resumes it.
    /// The app's own `pip(false)` (`byApp`) is no listener closing it. Pinned by `QTBridgePictureInPictureTests`.
    static let pictureInPicture = """
    (() => {
      const P = { inPip: false, left: 0, byApp: 0 };
      window.__qtPip = {
        byApp() { P.byApp = Date.now(); },
        tick(s, hold, eligible) {
          const now = Date.now();
          if (P.inPip && !s.pip && now - P.byApp > 1500) P.left = now;
          P.inPip = s.pip;
          if (!eligible) return null;
          if (hold && !s.paused && s.pip) return 'play';
          if (!hold && s.paused && s.ps === 2 && (s.pip || now - P.left < 3000)) { P.left = 0; return 'pause'; }
          return null;
        },
      };
    })();
    """

    /// Keeps a listening page from pausing itself (page world, document start, before the bridge so its timers are the
    /// raw ones — they run while the page's own are frozen). YouTube Music pauses after a while without input and asks
    /// "Still listening?" (`ytmusic-you-there-renderer`); the check compares its activity stamp `window._lact` with
    /// the clock. While the app wants music the stamp is refreshed once a minute, and a prompt is answered whenever
    /// one shows — on the bridge's reports, and every 2 s for half a minute after the page paused by itself (the
    /// prompt can come after the pause, with no media event). The queue resumes the media itself
    /// (`QTQueueController.superviseTick`). Selectors and the stamp follow YouTube's page and may drift:
    /// `QTBridgeKeepAliveTests` pin the behaviour, the live soak (`Scripts/playback-soak.py`) catches drift.
    static let keepAlive = """
    (() => {
      if (window.__qtKeepAlive) return;
      const raw = { si: setInterval.bind(window), ci: clearInterval.bind(window) };
      const PROMPT = 'ytmusic-you-there-renderer button, ytmusic-you-there-renderer tp-yt-paper-button, '
                   + 'ytmusic-you-there-renderer yt-button-renderer';
      const K = { want: false, paused: false, retry: 0, tries: 0, clicks: 0, stamps: 0 };
      function stamp() { try { window._lact = Date.now(); K.stamps++; } catch (_) {} }
      function dismiss() {
        const b = document.querySelector(PROMPT);
        if (!b) return false;
        try { b.click(); K.clicks++; } catch (_) {}
        return true;
      }
      function stopRetry() { if (K.retry) raw.ci(K.retry); K.retry = 0; }
      raw.si(() => { if (K.want) { stamp(); dismiss(); } }, 60000);
      window.__qtKeepAlive = {
        // Every bridge report: `want` = the app wants this page playing (not held); `paused` = its item's media is paused.
        tick(want, paused) {
          K.want = !!want; K.paused = !!paused;
          if (!K.want || !K.paused) { stopRetry(); return; }
          stamp(); dismiss();
          if (K.retry) return;
          K.tries = 0;
          K.retry = raw.si(() => {
            if (!K.want || !K.paused || ++K.tries > 15) { stopRetry(); return; }
            stamp(); dismiss();
          }, 2000);
        },
        info() { return { want: K.want, retrying: !!K.retry, clicks: K.clicks, stamps: K.stamps }; },
      };
    })();
    """

    /// Playback speed (page world, document start, before the bridge). The wanted rate goes on YouTube's player
    /// (`setPlaybackRate`, so its own state agrees and it doesn't put 1× back) and on the media element (`playbackRate`,
    /// `preservesPitch`), and is put back whenever the page changes it (`ratechange`, a new source). Ads always play at
    /// 1×: a sped-up ad is an ad-skipping trick, and the app shouldn't look like one. The bridge's `rate(r)` sets it,
    /// its samples report the media's rate (`tick`); a fresh page starts at `__qtInit.rate`. `QTBridgeRateTests` pin it.
    static let rate = """
    (() => {
      if (window.__qtRate) return;
      const init = window.__qtInit || {};
      const R = { want: +init.rate > 0 ? +init.rate : 1, applied: 1, asserts: 0, burstAt: 0, burst: 0 };
      const player = () => document.getElementById('movie_player');
      const video = () => { const p = player(); return (p && p.querySelector('video')) || document.querySelector('video'); };
      function isAd(p) {
        if (!p) return false;
        try { if (p.getPresentingPlayerType && p.getPresentingPlayerType() === 2) return true; } catch (_) {}
        return !!p.classList && (p.classList.contains('ad-showing') || p.classList.contains('ad-interrupting'));
      }
      // `ad`: the bridge's own reading (null: look here). Returns the rate the media plays at now.
      function apply(ad) {
        const p = player(), v = video(), r = (ad == null ? isAd(p) : ad) ? 1 : R.want;
        try { if (p && p.setPlaybackRate && (!p.getPlaybackRate || p.getPlaybackRate() !== r)) p.setPlaybackRate(r); } catch (_) {}
        if (v) {
          try { v.preservesPitch = true; v.webkitPreservesPitch = true; } catch (_) {}
          if (v.playbackRate !== r) try { v.playbackRate = r; R.asserts++; } catch (_) {}
        }
        R.applied = r;
        const now = v ? v.playbackRate : r;
        return (typeof now === 'number' && isFinite(now) && now > 0) ? now : r;
      }
      // Put back at once when the page changes it — at most a few times a second, so a page that keeps fighting
      // can't loop; the bridge's next sample tries again.
      function changed() {
        const now = Date.now();
        if (now - R.burstAt > 1000) { R.burstAt = now; R.burst = 0; }
        if (++R.burst <= 6) apply(null);
      }
      for (const ev of ['ratechange', 'loadedmetadata', 'playing']) document.addEventListener(ev, changed, true);
      window.__qtRate = {
        set(r) { R.want = Math.min(2, Math.max(0.5, +r || 1)); return apply(null); },
        // Every bridge sample: follows an ad starting or ending; reports the media's rate.
        tick(ad) { return apply(!!ad); },
        info() { return { want: R.want, applied: R.applied, asserts: R.asserts }; },
      };
    })();
    """

    /// The bridge (page world, document start). Waits for `#movie_player`, then reports.
    static let bridge = """
    (() => {
      if (window.__qtBridge) return;
      const init = window.__qtInit || {};
      // Timer freezer (see header). The page's setTimeout/setInterval go through synthetic ids so frozen timers
      // can be dropped and re-armed; the bridge itself uses the raw ones.
      const raw = { st: setTimeout.bind(window), ct: clearTimeout.bind(window), si: setInterval.bind(window), ci: clearInterval.bind(window) };
      const F = { frozen: false, next: 0x40000000, timers: new Map(), idle: [] };
      function arm(id, t) {
        t.real = t.every ? raw.si(() => t.fn.apply(window, t.args), t.ms)
                         : raw.st(() => { F.timers.delete(id); t.fn.apply(window, t.args); }, Math.max(0, t.due - Date.now()));
      }
      function disarm(t) { if (t.real != null) (t.every ? raw.ci : raw.ct)(t.real); t.real = null; }
      function wrap(every) {
        return function (fn, ms, ...args) {
          if (typeof fn !== 'function') return (every ? raw.si : raw.st)(fn, ms, ...args);
          const id = F.next++, d = Math.max(0, +ms || 0), t = { fn, args, ms: d, every, due: Date.now() + d, real: null };
          F.timers.set(id, t); if (!F.frozen) arm(id, t); return id;
        };
      }
      function unwrap(every) {
        return function (id) { const t = F.timers.get(id); if (!t) return (every ? raw.ci : raw.ct)(id); disarm(t); F.timers.delete(id); };
      }
      window.setTimeout = wrap(false); window.setInterval = wrap(true);
      window.clearTimeout = unwrap(false); window.clearInterval = unwrap(true);
      if (window.requestIdleCallback) {
        const ric = window.requestIdleCallback.bind(window);
        window.requestIdleCallback = (fn, o) => ric((d) => F.frozen ? F.idle.push(fn) : fn(d), o);
      }
      function freeze() { if (F.frozen) return; F.frozen = true; for (const t of F.timers.values()) disarm(t); }
      function thaw() {
        if (!F.frozen) return; F.frozen = false;
        for (const [id, t] of F.timers) arm(id, t);
        const idle = F.idle.splice(0); for (const fn of idle) raw.st(() => fn({ didTimeout: true, timeRemaining: () => 0 }), 0);
      }
      // target: requested id. resolved: the id the player actually plays for it (YouTube Music may swap a
      // video for its audio track) — the first new id seen after a load. armed: content played this generation.
      const S = { gen: init.gen || 0, target: init.target || '', resolved: '', prevVid: '', armed: false,
                  hold: !!init.hold, endedGen: -1, vol: init.vol == null ? 1 : init.vol, muted: !!init.muted,
                  last: null, lastPost: 0, attached: false, low: init.lowQuality !== false, errGen: -1,
                  qualityGen: -1, qualityKey: '', present: !!init.present, quality: init.quality || 'tiny', nav: true };
      // A Song⇄Video standby page stays muted at the source until its crossfade starts (`fade` unmutes): the
      // player may start before the bridge has attached and applied the volume.
      if (init.standby) {
        const hush = (e) => { if (S.muted) try { e.target.muted = true; } catch (_) {} };
        for (const ev of ['loadstart', 'loadedmetadata', 'play', 'playing']) document.addEventListener(ev, hush, true);
      }
      // The video surface lives in `videoSurface` (window.__qtVideo); the bridge only says when it shows.
      const present = () => { if (window.__qtVideo) window.__qtVideo.present(S.present); };
      present();
      document.addEventListener('DOMContentLoaded', present);
      const post = (m) => { try { window.webkit.messageHandlers.\(handlerName).postMessage(m); } catch (_) {} };
      const player = () => document.getElementById('movie_player');
      const video = () => { const p = player(); return (p && p.querySelector('video')) || document.querySelector('video'); };
      const visible = (el) => !!el && el.offsetParent !== null && getComputedStyle(el).visibility !== 'hidden';
      const num = (x) => (typeof x === 'number' && isFinite(x)) ? x : 0;

      function isAd(p) {
        if (!p) return false;
        try { if (p.getPresentingPlayerType && p.getPresentingPlayerType() === 2) return true; } catch (_) {}
        return p.classList.contains('ad-showing') || p.classList.contains('ad-interrupting');
      }
      function videoID(p) {
        try { const d = p.getVideoData(); return (d && (d.video_id || d.videoId)) || ''; } catch (_) { return ''; }
      }
      function adInfo(v) {
        const skip = document.querySelector('.ytp-skip-ad-button, .ytp-ad-skip-button, .ytp-ad-skip-button-modern');
        const preview = document.querySelector('.ytp-preview-ad, .ytp-ad-preview-container, .ytp-ad-preview-text, .ytp-preview-ad__text');
        let skippableIn = null;
        if (visible(skip)) skippableIn = 0;
        else if (visible(preview)) { const m = (preview.textContent || '').match(/(\\d+)/); if (m) skippableIn = +m[1]; }
        const d = v ? num(v.duration) : 0;
        return { duration: d, remaining: Math.max(0, d - (v ? num(v.currentTime) : 0)), skippableIn };
      }
      function sample() {
        const p = player(), v = video();
        const ad = isAd(p);
        let ps = -1; try { ps = p.getPlayerState(); } catch (_) {}
        let t = 0, d = 0;
        try { t = num(p.getCurrentTime()); d = num(p.getDuration()); } catch (_) {}
        if (!ad && v && !d) { t = num(v.currentTime); d = num(v.duration); }
        const paused = v ? v.paused : true;
        const vid = videoID(p);
        // Never learn the resolved id from an ad: while one presents, the player may report the ad's own id, and
        // content that then shows under the real id would never match again (the app froze on "Ad · 0:00").
        if (!S.resolved && vid && !ad && (vid !== S.prevVid || vid === S.target)) S.resolved = vid;
        else if (!S.resolved && !ad && S.nav && location.pathname !== '/watch' && S.errGen !== S.gen) {
          // A watch URL for an id that doesn't exist redirects to Home with an empty player.
          S.errGen = S.gen; post({ type: 'error', gen: S.gen, vid: S.target, code: 100, status: '', reason: 'redirected' });
        } else if (S.resolved && vid && vid !== S.resolved && vid === S.target && !ad) {
          // The requested item itself (e.g. after an ad that reported its own id): adopt it.
          S.resolved = vid;
        } else if (S.resolved && vid && vid !== S.resolved && !ad && !S.armed && !S.reasserted && p.loadVideoById) {
          // Something (a late YouTube navigation) replaced the requested item before it played: ask once more,
          // then accept whatever the page settles on.
          S.reasserted = true; S.resolved = ''; S.prevVid = vid;
          try { p.loadVideoById({ videoId: S.target, startSeconds: S.start }); } catch (_) {}
        }
        // An ad belongs to this load once the page has moved on from the previous item (pre-roll before the
        // content resolves, or between ads of a pod); post-load content must match the resolved id.
        const match = ad ? (!!vid && (vid === S.resolved || vid === S.target || vid !== S.prevVid))
                         : (!!S.resolved && vid === S.resolved);
        if (match && !ad && ps === 1 && d > 0 && t < d - 1) S.armed = true;
        if (!ad && S.errGen !== S.gen) checkPlayability(p);
        if (match && !ad && (S.qualityGen !== S.gen || S.qualityKey !== wantedQuality())) applyQuality(p);
        if (window.__qtVideo) window.__qtVideo.tick(ad, paused);
        return { type: 'state', gen: S.gen, vid, match, t, d, paused, ps,
                 buffering: !paused && (ps === 3 || (v && v.readyState < 3)),
                 ad: ad ? adInfo(v) : null, vol: S.vol, muted: S.muted,
                 vw: v ? num(v.videoWidth) : 0, vh: v ? num(v.videoHeight) : 0, rs: v ? num(v.readyState) : 0,
                 pip: !!v && v.webkitPresentationMode === 'picture-in-picture', rate: window.__qtRate ? window.__qtRate.tick(ad) : 1,
                 pic: window.__qtVideo ? window.__qtVideo.pictureBars() : [0, 0, 0, 0] };
      }
      function changed(a, b) {
        if (!b) return true;
        if (a.vid !== b.vid || a.paused !== b.paused || a.ps !== b.ps || a.buffering !== b.buffering || a.d !== b.d) return true;
        if (a.pip !== b.pip || (a.vw > 0) !== (b.vw > 0) || (a.rs >= 2) !== (b.rs >= 2)) return true;
        if (!!a.ad !== !!b.ad) return true;
        if (a.pic.some((x, i) => Math.abs(x - b.pic[i]) > 0.01)) return true;
        if (a.ad && (Math.ceil(a.ad.remaining) !== Math.ceil(b.ad.remaining) || a.ad.skippableIn !== b.ad.skippableIn)) return true;
        return a.rate !== b.rate || Math.abs(a.t - b.t) > 1.2 * Math.max(1, a.rate);
      }
      function report(force) {
        if (!player()) return;
        const s = sample();
        const now = Date.now();
        // The listener's Play / Pause in the Picture in Picture window (`pictureInPicture`): drops or sets the hold.
        const pip = window.__qtPip ? window.__qtPip.tick(s, S.hold, s.match && !s.ad && S.armed && S.endedGen !== S.gen) : null;
        if (pip) { S.hold = pip === 'pause'; if (!S.hold) thaw(); post({ type: 'pip', gen: S.gen, playing: !S.hold }); }
        if (S.hold && !s.paused) { pauseNow(); s.paused = true; }
        // Paused by the page while the app wants music ("Still listening?"): `keepAlive` answers it.
        if (window.__qtKeepAlive) window.__qtKeepAlive.tick(!S.hold, s.paused && s.match);
        if (force || changed(s, S.last) || now - S.lastPost > 5000) { S.last = s; S.lastPost = now; post(s); }
        maybeEnded(s);
      }
      function maybeEnded(s) {
        if (s.ad || !s.match || !S.armed || S.endedGen === S.gen) return;
        // End just before the media does: YouTube Music never reaches ENDED, so it never starts its own autoplay
        // pick (which would race the app's next load). The last half second of a track is its fade-out tail (wider when
        // sped up: half a second of listening, and samples land further apart).
        const atEnd = s.ps === 0 || (s.d > 0 && s.t >= s.d - 0.5 * Math.max(1, s.rate));
        if (atEnd) {
          S.endedGen = S.gen; S.hold = true;
          pauseNow();
          post({ type: 'ended', gen: S.gen, vid: S.resolved });
        }
      }
      // Age gates, region locks and removed videos often never raise onError; their player response says so.
      function checkPlayability(p) {
        let r = null; try { r = p.getPlayerResponse && p.getPlayerResponse(); } catch (_) {}
        const st = r && r.playabilityStatus, id = r && r.videoDetails && r.videoDetails.videoId;
        if (!st || !st.status || st.status === 'OK' || (id && id !== S.target && id !== S.resolved)) return;
        S.errGen = S.gen;
        const age = !!st.desktopLegacyAgeGateReason || /^AGE_/.test(st.status) || /\\bage\\b/i.test(st.reason || '');
        post({ type: 'error', gen: S.gen, vid: S.target, code: -1, status: String(st.status), reason: String(st.reason || ''), age });
      }
      // Lowest rendition while nothing shows the video; the slot's size while the app presents it.
      function wantedQuality() {
        const v = video();
        if (v && v.webkitPresentationMode === 'picture-in-picture') return 'hd720';   // floating on its own
        return S.present ? S.quality : (S.low ? 'tiny' : '');
      }
      // The first time per load the quality is pinned (min = max), as the content starts. Later changes (the video
      // moving between the hidden host, the panel, the Stage, PiP) only move the ceiling: pinning makes YouTube drop
      // its buffer and reload the media — ~0.35 s of silence and a frozen picture on every Now Playing ⇄ Queue
      // switch — while a ceiling lets its ABR change rendition at the next segment, with no gap. ('tiny' alone is a
      // pin, so the hidden ceiling is 'small'.)
      function applyQuality(p) {
        const q = wantedQuality();
        const first = S.qualityGen !== S.gen;
        S.qualityGen = S.gen; S.qualityKey = q;
        if (!q) return;
        try {
          if (first) { p.setPlaybackQualityRange(q, q); p.setPlaybackQuality(q); }
          else p.setPlaybackQualityRange('tiny', q === 'tiny' ? 'small' : q);
        } catch (_) {}
      }
      function pauseNow() { try { player().pauseVideo(); } catch (_) {} const v = video(); if (v) try { v.pause(); } catch (_) {} }
      function applyVolume() {
        const p = player(); if (!p) return;
        try { p.setVolume(Math.round(S.vol * 100)); S.muted ? p.mute() : p.unMute(); } catch (_) {}
      }
      function attach() {
        const p = player();
        if (!p || !p.getPlayerState || S.attached) return !!S.attached;
        S.attached = true;
        for (const ev of ['play', 'playing', 'pause', 'waiting', 'seeked', 'durationchange', 'ended', 'loadedmetadata', 'emptied',
                          'loadeddata', 'resize', 'webkitpresentationmodechanged']) {
          document.addEventListener(ev, () => report(ev !== 'loadedmetadata'), true);
        }
        document.addEventListener('timeupdate', () => report(false), true);
        try { p.addEventListener('onStateChange', () => report(true)); } catch (_) {}
        try { p.addEventListener('onError', (code) => { if (S.errGen === S.gen) return; S.errGen = S.gen;
          post({ type: 'error', gen: S.gen, vid: S.target, code: +code || 0, status: '', reason: '' }); }); } catch (_) {}
        new MutationObserver(() => report(false)).observe(p, { attributes: true, attributeFilter: ['class'] });
        applyVolume();
        post({ type: 'ready' });
        report(true);
        // Until the item resolves nothing may fire an event (redirected, unplayable): look once a second.
        const poll = raw.si(() => { if (S.resolved || S.errGen === S.gen) raw.ci(poll); else report(false); }, 1000);
        return true;
      }

      window.__qtBridge = {
        load(id, start, autoplay, gen) {
          thaw(); const p = player(); if (!p || !p.loadVideoById) return false;
          S.prevVid = videoID(p);
          S.gen = gen; S.target = id; S.start = start || 0; S.reasserted = false; S.nav = false;
          S.resolved = id === S.prevVid ? id : ''; S.armed = false; S.endedGen = -1; S.hold = !autoplay; S.last = null;
          const args = { videoId: id, startSeconds: Math.max(0, start || 0) };
          if (autoplay) p.loadVideoById(args); else p.cueVideoById(args);
          applyVolume();
          raw.st(() => report(true), 0);
          return true;
        },
        play() { thaw(); S.hold = false; const p = player(); if (!p) return false;
                 if (S.endedGen === S.gen) { S.endedGen = -1; p.seekTo(0, true); }
                 p.playVideo(); return true; },
        pause() { S.hold = true; pauseNow(); report(true); return true; },
        seek(t) { thaw(); const p = player(); if (!p || isAd(p)) return false;
                  if (S.endedGen === S.gen && t < num(p.getDuration()) - 1) S.endedGen = -1;
                  p.seekTo(Math.max(0, t), true); report(true); return true; },
        volume(v, muted) { thaw(); S.vol = v; S.muted = muted; applyVolume(); report(true); return true; },
        rate(r) { if (!window.__qtRate) return false; window.__qtRate.set(r); report(true); return true; },
        // Where the Skip button is (viewport CSS px) — YouTube ignores untrusted script clicks, so the engine
        // delivers a real click to its own offscreen view.
        skipTarget() {
          const b = document.querySelector('.ytp-skip-ad-button, .ytp-ad-skip-button, .ytp-ad-skip-button-modern');
          if (!visible(b)) return null;
          b.scrollIntoView({ block: 'center', inline: 'center' });
          const r = b.getBoundingClientRect();
          return { x: r.left + r.width / 2, y: r.top + r.height / 2, w: innerWidth, h: innerHeight };
        },
        sample() { return player() ? sample() : null; },
        // Only while paused on content; any command thaws. Returns whether the page is frozen now.
        freeze() { const v = video(); if (!S.hold || !v || !v.paused || isAd(player())) return false; freeze(); return true; },
        thaw() { thaw(); return true; },
        // Bare video surface on/off, with the quality that fits the slot ('tiny' … 'hd1080').
        present(on, quality) {
          S.present = !!on; if (quality) S.quality = quality;
          present();
          const p = player(); if (p && p.setPlaybackQualityRange) applyQuality(p);
          report(true); return true;
        },
        // Song⇄Video crossfade between two pages: ramps the player's volume along an equal-power curve over `ms`;
        // 'in' rises from silence to `to`, 'out' falls from `to` to silence. `muted` is the app's mute.
        fade(to, ms, dir, muted) {
          thaw(); const p = player(); if (!p || !p.setVolume) return false;
          if (S.fade) raw.ci(S.fade);
          S.muted = !!muted;
          const t0 = Date.now(), set = (x) => { try { p.setVolume(Math.max(0, Math.min(100, Math.round(x * 100)))); } catch (_) {} };
          set(dir === 'in' ? 0 : to);
          try { S.muted ? p.mute() : p.unMute(); } catch (_) {}
          S.fade = raw.si(() => {
            const k = Math.min(1, (Date.now() - t0) / Math.max(1, ms));
            set(to * (dir === 'in' ? Math.sin(k * Math.PI / 2) : Math.cos(k * Math.PI / 2)));
            if (k >= 1) { raw.ci(S.fade); S.fade = 0; if (dir === 'in') S.vol = to; }
          }, 16);
          return true;
        },
        // WebKit's native Picture in Picture for the page's video.
        pip(on) {
          const v = video(); if (!v || typeof v.webkitSetPresentationMode !== 'function') return false;
          if (window.__qtPip) window.__qtPip.byApp();
          if (on) {
            v.disablePictureInPicture = false;
            if (v.webkitSupportsPresentationMode && !v.webkitSupportsPresentationMode('picture-in-picture')) return false;
          }
          try { v.webkitSetPresentationMode(on ? 'picture-in-picture' : 'inline'); } catch (_) { return false; }
          raw.st(() => report(true), 300);
          return true;
        },
        isFrozen() { return F.frozen; },
        media() { const v = video(); return v ? { volume: v.volume, muted: v.muted, surface: window.__qtVideo ? window.__qtVideo.info() : null, width: v.videoWidth, height: v.videoHeight,
                                                  quality: (() => { try { return player().getPlaybackQuality(); } catch (_) { return ''; } })() } : null; },
      };
      const timer = raw.si(() => { if (attach()) raw.ci(timer); }, 250);
    })();
    """
}
