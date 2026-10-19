import Foundation

/// The whole JavaScript side of `QTWebPlaybackEngine`. Deliberately tiny (Kaset's ~6k-line bridge is the
/// anti-pattern): it only *reports* the player's state and *forwards* six commands. It never touches YouTube
/// Music's queue, never registers `navigator.mediaSession` handlers and never decides what plays next — the
/// app's `QTQueueController` does.
///
/// Messages (`window.webkit.messageHandlers.qtPlayback`):
/// - `{type:"ready"}` once the page's player API exists;
/// - `{type:"state", gen, vid, t, d, paused, ps, buffering, ad, vol, muted}` on media events (≤ 2/s);
/// - `{type:"ended", gen, vid}` exactly once per load generation when content (not an ad) finishes;
/// - `{type:"error", gen, vid, code, status, reason}` when the player reports an error or the item's
///   playability status isn't OK (age-restricted, region-locked, removed…).
///
/// Power: while the app shows no video (always, for now) the bridge asks for the lowest video quality, so the
/// hidden view decodes 144p at most; and while paused the engine *freezes* the page's timers (`freeze()`), so
/// YouTube Music's polling, heartbeats and UI timers stop until the next command thaws them.
enum QTWebPlaybackBridgeScript {
    /// Message handler name shared by the script and `QTWebPlaybackEngine`.
    static let handlerName = "qtPlayback"

    /// Injected at document start (page world): initial load parameters for the first document.
    static func bootstrap(generation: Int, videoID: String, hold: Bool, volume: Double, muted: Bool, silent: Bool,
                          lowQuality: Bool = true) -> String {
        let payload: [String: Any] = [
            "gen": generation, "target": videoID, "hold": hold, "vol": volume, "muted": muted, "silent": silent,
            "lowQuality": lowQuality,
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
                  last: null, lastPost: 0, attached: false, low: init.lowQuality !== false, errGen: -1, lowGen: -1,
                  nav: true };
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
        if (match && !ad && S.low && S.lowGen !== S.gen) lowestQuality(p);
        return { type: 'state', gen: S.gen, vid, match, t, d, paused, ps,
                 buffering: !paused && (ps === 3 || (v && v.readyState < 3)),
                 ad: ad ? adInfo(v) : null, vol: S.vol, muted: S.muted };
      }
      function changed(a, b) {
        if (!b) return true;
        if (a.vid !== b.vid || a.paused !== b.paused || a.ps !== b.ps || a.buffering !== b.buffering || a.d !== b.d) return true;
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
      function lowestQuality(p) {
        try { p.setPlaybackQualityRange('tiny', 'tiny'); p.setPlaybackQuality('tiny'); S.lowGen = S.gen; } catch (_) {}
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
        for (const ev of ['play', 'playing', 'pause', 'waiting', 'seeked', 'durationchange', 'ended', 'loadedmetadata', 'emptied']) {
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
        isFrozen() { return F.frozen; },
        media() { const v = video(); return v ? { volume: v.volume, muted: v.muted, width: v.videoWidth, height: v.videoHeight,
                                                  quality: (() => { try { return player().getPlaybackQuality(); } catch (_) { return ''; } })() } : null; },
      };
      const timer = raw.si(() => { if (attach()) raw.ci(timer); }, 250);
    })();
    """
}
