// Simulated playback engine. One rAF loop owns the clock; components subscribe at the rate they need,
// so a lyric line re-renders only while it is the current line (the opposite of a per-frame app re-render).
const { useState, useEffect, useRef, useCallback, useMemo, useSyncExternalStore } = React;

const NO_MV = new Set(["ne3372368359", "ne3392546056"]); // Hi-Res audio uploads, not music videos
const TRACKS = window.QT_DATA.tracks.map((t) => ({
  ...t,
  mv: NO_MV.has(t.id) ? null : t.mv || null,
  unavailable: t.id === "ne570019977", // greyed row, like a region-locked track
}));
const byId = Object.fromEntries(TRACKS.map((t) => [t.id, t]));

const AD_SECONDS = 12;

function createPlayer() {
  const listeners = new Set();
  const s = {
    trackId: TRACKS[0].id,
    position: 31.5, // just before the first lyric of the hero track
    playing: true,
    shuffle: false,
    repeat: false,
    liked: new Set(TRACKS.map((t) => t.id)),
    upNext: ["ne1968907343", "ne460043703"], // "you added" section
    history: [],
    ad: null, // { remaining, skippableAt }
    account: "premium",
    lyricOffset: 0,
    version: 0,
  };
  let last = performance.now();
  const emit = () => { s.version++; listeners.forEach((l) => l()); };
  const tick = (now) => {
    const dt = Math.min(0.25, (now - last) / 1000);
    last = now;
    if (s.playing) {
      if (s.ad) {
        s.ad.remaining -= dt;
        if (s.ad.remaining <= 0) { s.ad = null; s.position = 0; }
      } else {
        s.position += dt;
        const t = byId[s.trackId];
        if (s.position >= t.duration) api.next(true);
      }
    }
    timeListeners.forEach((l) => l());
    requestAnimationFrame(tick);
  };
  const timeListeners = new Set();
  const autoplay = () => TRACKS.filter((t) => !t.unavailable && t.id !== s.trackId && !s.upNext.includes(t.id));
  const api = {
    state: s,
    subscribe(l) { listeners.add(l); return () => listeners.delete(l); },
    subscribeTime(l) { timeListeners.add(l); return () => timeListeners.delete(l); },
    get track() { return byId[s.trackId]; },
    autoplay,
    play(id, { fromStart = true } = {}) {
      if (byId[id].unavailable) return;
      if (id !== s.trackId) s.history.push(s.trackId);
      s.trackId = id;
      s.upNext = s.upNext.filter((x) => x !== id);
      if (fromStart) s.position = 0;
      s.playing = true;
      s.ad = s.account === "free" ? { remaining: AD_SECONDS, skippableAt: AD_SECONDS - 5 } : null;
      emit();
    },
    toggle() { s.playing = !s.playing; emit(); },
    next(auto = false) {
      if (s.repeat && auto) { s.position = 0; emit(); return; }
      const nextId = s.upNext[0] || autoplay()[s.shuffle ? Math.floor(Math.random() * autoplay().length) : 0]?.id;
      if (nextId) api.play(nextId);
    },
    prev() {
      if (s.position > 3 || !s.history.length) { s.position = 0; emit(); return; }
      const id = s.history.pop();
      s.trackId = id; s.position = 0; s.ad = null; emit();
    },
    seek(sec) { if (s.ad) return; s.position = Math.max(0, Math.min(sec, api.track.duration - 0.5)); emit(); },
    like(id = s.trackId) { s.liked.has(id) ? s.liked.delete(id) : s.liked.add(id); emit(); },
    playNext(id) { s.upNext = [id, ...s.upNext.filter((x) => x !== id)]; emit(); },
    addToQueue(id) { if (!s.upNext.includes(id)) s.upNext = [...s.upNext, id]; emit(); },
    removeFromQueue(id) { s.upNext = s.upNext.filter((x) => x !== id); emit(); },
    clearUpNext() { const prev = s.upNext; s.upNext = []; emit(); return () => { s.upNext = prev; emit(); }; },
    setShuffle() { s.shuffle = !s.shuffle; emit(); },
    setRepeat() { s.repeat = !s.repeat; emit(); },
    setAccount(a) { s.account = a; if (a === "premium") s.ad = null; emit(); },
    playAd() { s.ad = { remaining: AD_SECONDS, skippableAt: AD_SECONDS - 5 }; s.playing = true; emit(); },
    skipAd() { s.ad = null; s.position = 0; emit(); },
    nudgeOffset(d) { s.lyricOffset = Math.round((s.lyricOffset + d) * 10) / 10; emit(); },
  };
  requestAnimationFrame(tick);
  return api;
}

const player = createPlayer();

// Re-render on state changes (track, play/pause, queue...).
function usePlayer() {
  useSyncExternalStore(player.subscribe, () => player.state.version);
  return player;
}

// Re-render on clock ticks, throttled to `fps`.
function usePosition(fps = 4) {
  const [, force] = useState(0);
  useEffect(() => {
    let lastT = 0;
    return player.subscribeTime(() => {
      const now = performance.now();
      if (now - lastT >= 1000 / fps) { lastT = now; force((n) => n + 1); }
    });
  }, [fps]);
  return player.state.position;
}

const fmt = (sec) => {
  sec = Math.max(0, Math.floor(sec));
  return `${Math.floor(sec / 60)}:${String(sec % 60).padStart(2, "0")}`;
};

function Scrubber({ className = "" }) {
  const p = usePlayer();
  const pos = usePosition(8);
  const t = p.track;
  const ad = p.state.ad;
  const ref = useRef(null);
  const pct = ad ? (1 - ad.remaining / AD_SECONDS) * 100 : (pos / t.duration) * 100;
  const onClick = (e) => {
    const r = ref.current.getBoundingClientRect();
    p.seek(((e.clientX - r.left) / r.width) * t.duration);
  };
  return (
    <div className={`scrub ${className}`}>
      <span>{ad ? tr("Ad") : fmt(pos)}</span>
      <div className={`track ${ad ? "disabled" : ""}`} ref={ref} onClick={onClick}>
        <div className="fill" style={{ width: `${pct}%`, background: ad ? "#f6c343" : undefined }} />
        <div className="knob" style={{ left: `${pct}%` }} />
      </div>
      <span>{ad ? `0:${String(Math.ceil(ad.remaining)).padStart(2, "0")}` : `-${fmt(t.duration - pos)}`}</span>
    </div>
  );
}

function Transport({ size = 16, playSize = 18 }) {
  const p = usePlayer();
  const s = p.state;
  return (
    <>
      <button className={`tp small ${s.shuffle ? "on" : ""}`} title={tr("Shuffle")} onClick={p.setShuffle}><Icon name="shuffle" size={size} /></button>
      <button className="tp" title={tk("Previous", "⌘←")} onClick={p.prev} disabled={!!s.ad}><Icon name="prev" size={size + 2} /></button>
      <button className="tp play" title={tk(s.playing ? "Pause" : "Play", "Space")} onClick={p.toggle}>
        <Icon name={s.playing ? "pause" : "play"} size={playSize} />
      </button>
      <button className="tp" title={tk("Next", "⌘→")} onClick={() => (s.ad ? s.ad.remaining <= s.ad.skippableAt && p.skipAd() : p.next())}>
        <Icon name="next" size={size + 2} />
      </button>
      <button className={`tp small ${s.repeat ? "on" : ""}`} title={tr("Repeat")} onClick={p.setRepeat}><Icon name="repeat" size={size} /></button>
    </>
  );
}

// Free accounts: YouTube's ad plays; we show the song's own art, dimmed, with a quiet countdown.
function AdCard({ size = 312 }) {
  const p = usePlayer();
  usePosition(4);
  const ad = p.state.ad;
  if (!ad) return null;
  const canSkip = ad.remaining <= ad.skippableAt;
  return (
    <div className="ad-art" style={{ width: size, height: size }}>
      <div className="ad-bg" style={{ backgroundImage: `url(${p.track.cover})` }} />
      <div className="ad-center">
        <span className="ad-pill">{tr("Ad")} · 0:{String(Math.ceil(ad.remaining)).padStart(2, "0")}</span>
        {canSkip ? <button className="ad-skip" onClick={p.skipAd}>{tr("Skip")}</button> : <span className="ad-wait">{tr("Skip in {n}", { n: Math.ceil(ad.remaining - ad.skippableAt) })}</span>}
      </div>
    </div>
  );
}

// Hooks are exported too: other Babel files use them bare and must not redeclare them.
Object.assign(window, { useState, useEffect, useRef, useCallback, useMemo, useSyncExternalStore, player, usePlayer, usePosition, TRACKS, byId, fmt, Scrubber, Transport, AdCard, AD_SECONDS });
