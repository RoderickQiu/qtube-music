import Foundation

/// The whole JavaScript side of `QTWebPlaybackEngine`. Deliberately tiny (Kaset's ~6k-line bridge is the
/// anti-pattern): it only *reports* the player's state and *forwards* six commands. It never touches YouTube
/// Music's queue, never registers `navigator.mediaSession` handlers and never decides what plays next — the
/// app's `QTQueueController` does.
///
/// Messages (`window.webkit.messageHandlers.qtPlayback`):
/// - `{type:"ready"}` once the page's player API exists;
/// - `{type:"state", gen, vid, t, d, paused, ps, buffering, ad, vol, muted, vw, vh, rs, pip}` on media events (≤ 2/s);
/// - `{type:"ended", gen, vid}` exactly once per load generation when content (not an ad) finishes;
/// - `{type:"error", gen, vid, code, status, reason}` when the player reports an error or the item's
///   playability status isn't OK (age-restricted, region-locked, removed…).
///
/// Power: while the app shows no video the bridge asks for the lowest video quality, so the hidden view decodes
/// 144p at most; and while paused the engine *freezes* the page's timers (`freeze()`), so YouTube Music's
/// polling, heartbeats and UI timers stop until the next command thaws them.
///
/// Video (M5, separate `videoSurface` script): the bridge's `present(on, quality)` turns the page into a bare video
/// surface — every element is hidden (`visibility`, so YouTube's own layout and logic keep running), each decoded
/// frame is drawn onto one full-viewport canvas (`object-fit: cover`, burned-in letterbox bars cropped), nothing
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
                          lowQuality: Bool = true, present: Bool = false, quality: String = "tiny") -> String {
        let payload: [String: Any] = [
            "gen": generation, "target": videoID, "hold": hold, "vol": volume, "muted": muted, "silent": silent,
            "lowQuality": lowQuality, "present": present, "quality": quality,
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
      // Letterbox bars burned into the stream (a 2.39:1 film in a 16:9 upload) are measured on a tiny probe every
      // couple of seconds and cropped away, so a full-bleed slot never shows black bands.
      const C = { canvas: null, ctx: null, running: false, v: null, handle: 0, bar: 0, probe: null, lastProbe: 0, probes: 0, src: "" };
      function measureBars(v) {
        const now = Date.now();
        if (C.src !== v.currentSrc) { C.src = v.currentSrc; C.bar = 0; C.lastProbe = 0; C.probes = 0; }
        if (now - C.lastProbe < (C.probes < 10 ? 250 : 2000)) return;   // quick at the start, then calm
        C.lastProbe = now; C.probes++;
        if (!C.probe) { C.probe = document.createElement('canvas'); C.probe.width = 32; C.probe.height = 72; }
        const p = C.probe.getContext('2d', { willReadFrequently: true });
        try {
          p.drawImage(v, 0, 0, 32, 72);
          const d = p.getImageData(0, 0, 32, 72).data;
          const dark = (row) => { let m = 0; for (let x = 0; x < 32; x++) { const i = (row * 32 + x) * 4; m = Math.max(m, d[i], d[i + 1], d[i + 2]); } return m < 22; };
          let top = 0; while (top < 18 && dark(top)) top++;
          let bottom = 0; while (bottom < 18 && dark(71 - bottom)) bottom++;
          const bar = Math.min(top, bottom) / 72;
          // Only a clear, symmetric band counts (a dark scene is not a letterbox: it must also be lit inside).
          const lit = !dark(36) || !dark(30) || !dark(42);
          C.bar = lit && bar >= 0.04 ? Math.min(0.3, bar + 0.01) : (lit ? 0 : C.bar);   // +1 % clears the soft edge
        } catch (_) {}
      }
      function frameTarget(v, sh) {
        const dpr = window.devicePixelRatio || 2, vw = v.videoWidth;
        const cover = Math.max(innerWidth * dpr / vw, innerHeight * dpr / sh);
        const k = Math.min(1, cover);   // never larger than the decoded frame
        return [Math.max(2, Math.round(vw * k)), Math.max(2, Math.round(sh * k))];
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
          const vw = v.videoWidth, vh = v.videoHeight, sy = Math.round(vh * C.bar), sh = vh - 2 * sy;
          const [w, h] = frameTarget(v, sh);
          if (C.canvas.width !== w || C.canvas.height !== h) { C.canvas.width = w; C.canvas.height = h; }
          try { C.ctx.drawImage(v, 0, sy, vw, sh, 0, 0, w, h); } catch (_) {}
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
        info() { return { letterbox: C.bar, canvas: C.canvas ? C.canvas.width + 'x' + C.canvas.height : '' }; },
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
        if (!S.resolved && vid && vid !== S.prevVid) S.resolved = vid;
        else if (!S.resolved && S.nav && location.pathname !== '/watch' && S.errGen !== S.gen) {
          // A watch URL for an id that doesn't exist redirects to Home with an empty player.
          S.errGen = S.gen; post({ type: 'error', gen: S.gen, vid: S.target, code: 100, status: '', reason: 'redirected' });
        } else if (S.resolved && vid && vid !== S.resolved && !ad && !S.armed && !S.reasserted && p.loadVideoById) {
          // Something (a late YouTube navigation) replaced the requested item before it played: ask once more,
          // then accept whatever the page settles on.
          S.reasserted = true; S.resolved = ''; S.prevVid = vid;
          try { p.loadVideoById({ videoId: S.target, startSeconds: S.start }); } catch (_) {}
        }
        const match = !!S.resolved && vid === S.resolved;
        if (match && !ad && ps === 1 && d > 0 && t < d - 1) S.armed = true;
        if (!ad && S.errGen !== S.gen) checkPlayability(p);
        if (match && !ad && (S.qualityGen !== S.gen || S.qualityKey !== wantedQuality())) applyQuality(p);
        if (window.__qtVideo) window.__qtVideo.tick(ad, paused);
        return { type: 'state', gen: S.gen, vid, match, t, d, paused, ps,
                 buffering: !paused && (ps === 3 || (v && v.readyState < 3)),
                 ad: ad ? adInfo(v) : null, vol: S.vol, muted: S.muted,
                 vw: v ? num(v.videoWidth) : 0, vh: v ? num(v.videoHeight) : 0, rs: v ? num(v.readyState) : 0,
                 pip: !!v && v.webkitPresentationMode === 'picture-in-picture' };
      }
      function changed(a, b) {
        if (!b) return true;
        if (a.vid !== b.vid || a.paused !== b.paused || a.ps !== b.ps || a.buffering !== b.buffering || a.d !== b.d) return true;
        if (a.pip !== b.pip || (a.vw > 0) !== (b.vw > 0) || (a.rs >= 2) !== (b.rs >= 2)) return true;
        if (!!a.ad !== !!b.ad) return true;
        if (a.ad && (Math.ceil(a.ad.remaining) !== Math.ceil(b.ad.remaining) || a.ad.skippableIn !== b.ad.skippableIn)) return true;
        return Math.abs(a.t - b.t) > 1.2;
      }
      function report(force) {
        if (!player()) return;
        const s = sample();
        const now = Date.now();
        if (S.hold && !s.paused) { pauseNow(); s.paused = true; }
        else if (!S.hold && s.paused && s.match) dismissPrompts();  // paused by the page ("Still listening?")
        if (force || changed(s, S.last) || now - S.lastPost > 5000) { S.last = s; S.lastPost = now; post(s); }
        maybeEnded(s);
      }
      function maybeEnded(s) {
        if (s.ad || !s.match || !S.armed || S.endedGen === S.gen) return;
        // End just before the media does: YouTube Music never reaches ENDED, so it never starts its own autoplay
        // pick (which would race the app's next load). The last half second of a track is its fade-out tail.
        const atEnd = s.ps === 0 || (s.d > 0 && s.t >= s.d - 0.5);
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
      function applyQuality(p) {
        const q = wantedQuality();
        S.qualityGen = S.gen; S.qualityKey = q;
        if (!q) return;
        try { p.setPlaybackQualityRange(q, q); p.setPlaybackQuality(q); } catch (_) {}
      }
      function pauseNow() { try { player().pauseVideo(); } catch (_) {} const v = video(); if (v) try { v.pause(); } catch (_) {} }
      function applyVolume() {
        const p = player(); if (!p) return;
        try { p.setVolume(Math.round(S.vol * 100)); S.muted ? p.mute() : p.unMute(); } catch (_) {}
      }
      function dismissPrompts() {
        const b = document.querySelector('ytmusic-you-there-renderer button, ytmusic-you-there-renderer tp-yt-paper-button');
        if (b) b.click();
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
        // WebKit's native Picture in Picture for the page's video.
        pip(on) {
          const v = video(); if (!v || typeof v.webkitSetPresentationMode !== 'function') return false;
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
