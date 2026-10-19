// Stage: the immersive player. Layouts × backgrounds; chrome auto-hides while playing.

const STAGE_LAYOUTS = [
  { id: "standard", label: "Standard — art + lyrics" },
  { id: "lyrics-only", label: "Lyrics" },
  { id: "art-only", label: "Art" },
];
const STAGE_BACKGROUNDS = [
  { id: "blur", label: "Blurred artwork" },
  { id: "cover", label: "Full-bleed cover" },
  { id: "vinyl", label: "Vinyl" },
  { id: "video", label: "Music video" },
  { id: "visual", label: "Visualizer (Premium)" },
];

function Vinyl({ track, size = 460 }) {
  return (
    <div className="vinyl-wrap" style={{ width: size, height: size }}>
      <div className="record"><img src={track.cover} alt="" /></div>
      <svg className="tonearm" viewBox="0 0 150 300" aria-hidden="true">
        <circle cx="112" cy="34" r="22" fill="#d9d9dc" />
        <circle cx="112" cy="34" r="9" fill="#9a9aa0" />
        <path d="M112 34 L118 190 Q120 228 92 252" stroke="#e6e6e8" strokeWidth="7" fill="none" strokeLinecap="round" />
        <rect x="70" y="244" width="34" height="22" rx="4" transform="rotate(-38 87 255)" fill="#cfcfd2" />
      </svg>
    </div>
  );
}

function Visualizer({ track }) {
  const ref = useRef(null);
  useEffect(() => {
    const c = ref.current, g = c.getContext("2d");
    let raf, t0 = performance.now();
    const accent = getComputedStyle(c).getPropertyValue("--accent").trim() || "#fff";
    const size = () => { c.width = c.clientWidth; c.height = c.clientHeight; };
    size();
    addEventListener("resize", size);
    const draw = (now) => {
      const W = c.width, H = c.height;
      const playing = player.state.playing && !player.state.ad;
      const t = (now - t0) / 1000;
      g.clearRect(0, 0, W, H);
      const N = 96, bw = W / N;
      const beat = playing ? Math.pow(Math.max(0, Math.sin(t * Math.PI * 2 * 1.4)), 6) : 0;
      for (let i = 0; i < N; i++) {
        const x = i / N;
        const env = Math.exp(-Math.pow((x - 0.18) / 0.22, 2)) * 0.9 + Math.exp(-Math.pow((x - 0.55) / 0.3, 2)) * 0.5 + 0.08;
        const n = 0.55 + 0.45 * Math.sin(t * (2.1 + i * 0.13) + i) * Math.sin(t * 1.3 + i * 0.7);
        const h = playing ? (env * n + beat * env * 0.6) * H * 0.42 : H * 0.012;
        g.fillStyle = accent;
        g.globalAlpha = 0.18 + 0.5 * env;
        g.fillRect(i * bw + 1, H - h, bw - 2, h);
        g.globalAlpha = 0.07;
        g.fillRect(i * bw + 1, 0, bw - 2, h * 0.35);
      }
      raf = requestAnimationFrame(draw);
    };
    raf = requestAnimationFrame(draw);
    return () => { cancelAnimationFrame(raf); removeEventListener("resize", size); };
  }, [track.id]);
  return <canvas ref={ref} />;
}

function StageBackground({ kind, track }) {
  if (kind === "video") return <div className="st-bg video"><div className="img" style={{ backgroundImage: `url(${track.mv.still})` }} /><div className="shade" /></div>;
  if (kind === "cover") return <div className="st-bg cover"><div className="img" style={{ backgroundImage: `url(${track.cover})` }} /></div>;
  return (
    <div className="st-bg blur">
      <div className="img" style={{ backgroundImage: `url(${track.cover})` }} />
      <div className="img b" style={{ backgroundImage: `url(${track.cover})` }} />
      <div className="scrim" />
      {kind === "visual" && <div className="st-bg visual"><Visualizer track={track} /></div>}
    </div>
  );
}

function VideoLyricsOverlay({ track, translation }) {
  const pos = usePosition(10);
  const off = player.state.lyricOffset;
  const ln = currentLyric(track, pos + off);
  if (!ln) return null;
  return (
    <div style={{ position: "absolute", left: 64, right: 64, bottom: 150, "--ly-on": "#fff", "--ly-off": "rgba(255,255,255,.45)" }}>
      <div style={{ font: "700 40px/1.2 var(--font-display)", textShadow: "0 2px 18px rgba(0,0,0,.5)", maxWidth: 1000 }}>
        {ln.words ? <KaraokeLine line={ln} offset={off} /> : ln.text}
      </div>
      {translation && ln.tr && <div style={{ font: "600 22px/1.3 var(--font)", color: "rgba(255,255,255,.75)", marginTop: 6 }}>{ln.tr}</div>}
    </div>
  );
}

// Appearance: layout + background behind one quiet icon, chosen visually.
function AppearanceButton({ track, layout, setLayout, background, setBackground, isVideo, account }) {
  const [anchor, setAnchor] = useState(null);
  const layouts = [
    { id: "standard", label: "Art + lyrics", glyph: <><i className="g-art" /><i className="g-lines" /></> },
    { id: "lyrics-only", label: "Lyrics", glyph: <i className="g-lines c" /> },
    { id: "art-only", label: "Art", glyph: <i className="g-art c" /> },
  ];
  const bgs = [
    { id: "blur", label: "Blur", preview: <div className="sw-img blur" style={{ backgroundImage: `url(${track.cover})` }} /> },
    { id: "cover", label: "Cover", preview: <div className="sw-img" style={{ backgroundImage: `url(${track.cover})` }} /> },
    { id: "vinyl", label: "Vinyl", preview: <div className="sw-vinyl"><img src={track.cover} alt="" /></div> },
    { id: "video", label: "Video", preview: track.mv ? <div className="sw-img" style={{ backgroundImage: `url(${track.mv.still})` }} /> : <div className="sw-img none" />, disabled: !track.mv },
    { id: "visual", label: "Visualizer", preview: <div className="sw-bars">{[5, 9, 6, 11, 7, 4, 8].map((h, i) => <i key={i} style={{ height: h * 3 }} />)}</div>, disabled: account === "free" },
  ];
  const current = isVideo ? "video" : background;
  return (
    <>
      <button className="icon-ghost" title="Appearance" aria-label="Appearance" onClick={(e) => setAnchor(anchor ? null : e.currentTarget)}><Icon name="sparkle" size={16} /></button>
      {anchor && (
        <Popover anchor={anchor} onClose={() => setAnchor(null)} width={308}>
          {!isVideo && (
            <div className="sw-layouts">
              {layouts.map((l) => (
                <button key={l.id} className={`sw-layout ${layout === l.id ? "on" : ""}`} title={l.label} onClick={() => setLayout(l.id)}>{l.glyph}</button>
              ))}
            </div>
          )}
          <div className="sw-grid">
            {bgs.map((b) => (
              <button key={b.id} className={`sw ${current === b.id ? "on" : ""}`} disabled={b.disabled}
                title={b.id === "visual" && account === "free" ? "Premium" : b.label} onClick={() => setBackground(b.id)}>
                {b.preview}<span>{b.label}</span>
              </button>
            ))}
          </div>
        </Popover>
      )}
    </>
  );
}

function Stage({ layout, setLayout, background, setBackground, videoMode, setVideoMode, onClose, theme, translation, setTranslation, toast }) {
  const p = usePlayer();
  const t = p.track;
  const [chrome, setChrome] = useState(true);
  const [leaving, setLeaving] = useState(false);
  const [queueOpen, setQueueOpen] = useState(false);
  const timer = useRef(null);
  const isVideo = (videoMode || background === "video") && t.mv;
  const bg = isVideo ? "video" : background === "video" ? "blur" : background;
  const effectiveBg = bg === "visual" && p.state.account === "free" ? "blur" : bg;
  const ad = p.state.ad;

  const poke = useCallback(() => {
    setChrome(true);
    clearTimeout(timer.current);
    timer.current = setTimeout(() => player.state.playing && !document.querySelector(".pop, .st-queue") && setChrome(false), 2600);
  }, []);
  useEffect(() => { poke(); return () => clearTimeout(timer.current); }, [p.state.playing, poke]);

  const close = () => { setLeaving(true); setTimeout(onClose, 240); };
  useEffect(() => {
    const onKey = (e) => {
      if (e.key !== "Escape" || document.querySelector(".pop")) return;
      if (document.querySelector(".st-queue")) setQueueOpen(false); else close();
    };
    addEventListener("keydown", onKey);
    return () => removeEventListener("keydown", onKey);
  }, []);

  const setBg = (id) => { setBackground(id); setVideoMode(id === "video"); };
  const artSize = layout === "art-only" ? 480 : 440;
  const art = ad ? <AdCard size={artSize} />
    : effectiveBg === "vinyl" ? <Vinyl track={t} size={layout === "art-only" ? 500 : 440} />
    : effectiveBg === "cover" && layout === "standard" ? null
    : <img className="st-art" src={t.cover} alt="" style={layout === "art-only" ? { width: 480 } : undefined} />;
  const meta = (align = "left", small = false) => (
    <div className="st-meta" style={{ textAlign: align }}>
      <h1 style={small ? { fontSize: 20 } : undefined}>{t.title}</h1>
      <p style={small ? { fontSize: 13 } : undefined}>{t.artist}{small ? "" : ` — ${t.album}`}</p>
    </div>
  );

  return (
    <div className={`stage ${p.state.playing ? "playing-state" : "paused"} ${leaving ? "leaving" : ""}`} onMouseMove={poke} style={{ cursor: chrome ? "default" : "none" }}>
      <StageBackground kind={effectiveBg} track={t} />

      {isVideo ? (
        ad ? <div className="st-center"><AdCard size={440} /></div> : <VideoLyricsOverlay track={t} translation={translation} />
      ) : (
        <div className={`st-layout ${layout}`}>
          {layout !== "lyrics-only" && (
            <div className="st-art-col">
              {art}
              {(layout === "art-only" || effectiveBg === "vinyl") && meta("center")}
              {layout === "art-only" && !ad && <ArtOnlyLyric track={t} translation={translation} />}
            </div>
          )}
          {layout !== "art-only" && (
            <div className="st-lyrics-col">
              {layout === "lyrics-only" && <div style={{ position: "absolute", top: -6, left: 0, right: 0 }}>{meta("center", true)}</div>}
              {layout === "standard" && effectiveBg !== "vinyl" && <div style={{ position: "absolute", top: -4 }}>{meta("left")}</div>}
              <div className="lyrics-holder" style={{ position: "absolute", inset: layout === "lyrics-only" ? "56px 0 0" : "84px 0 0" }}>
                <LyricsView track={t} mode="stage" align={layout === "lyrics-only" ? "center" : "left"} translation={translation} anchor={0.4} />
              </div>
            </div>
          )}
        </div>
      )}

      <div className={`st-chrome ${chrome ? "" : "hidden"}`}>
        <div className="st-top">
          <button className="icon-ghost" title="Close  Esc" aria-label="Close Stage" onClick={close}><Icon name="chevD" size={18} /></button>
          <div className="grow" />
          <LyricsOptionsButton track={t} translation={translation} setTranslation={setTranslation} onToast={toast} />
          <AppearanceButton track={t} layout={layout} setLayout={setLayout} background={background} setBackground={setBg} isVideo={isVideo} account={p.state.account} />
          <div className="seg">
            <button className={!isVideo ? "on" : ""} onClick={() => { setVideoMode(false); if (background === "video") setBackground("blur"); }}>Song</button>
            <button className={isVideo ? "on" : ""} disabled={!t.mv} title={t.mv ? "" : "No music video"} onClick={() => setVideoMode(true)}>Video</button>
          </div>
        </div>
        <div className="st-bottom">
          <Scrubber />
          <div className="st-transport"><Transport size={20} playSize={22} /></div>
        </div>
        <div className="st-side">
          <button className={`tp small ${p.state.liked.has(t.id) ? "on" : ""}`} onClick={() => p.like()} aria-label="Like"><Icon name={p.state.liked.has(t.id) ? "heartFill" : "heart"} size={20} /></button>
          <button className={`tp small ${queueOpen ? "on" : ""}`} title="Queue" aria-label="Queue" onClick={() => setQueueOpen(!queueOpen)}><Icon name="list" size={20} /></button>
          <button className="tp small" title="AirPlay" aria-label="AirPlay"><Icon name="airplay" size={20} /></button>
        </div>
      </div>
      {queueOpen && (
        <div className="st-queue theme-dark">
          <div className="st-queue-head">
            <b>Queue</b>
            <button className="icon-ghost" aria-label="Close queue" onClick={() => setQueueOpen(false)}><Icon name="close" size={14} /></button>
          </div>
          <div className="st-queue-body"><UpNext toast={toast} /></div>
        </div>
      )}
    </div>
  );
}

function ArtOnlyLyric({ track, translation }) {
  const pos = usePosition(10);
  const off = player.state.lyricOffset;
  const ln = currentLyric(track, pos + off);
  return (
    <div style={{ textAlign: "center", minHeight: 64, "--ly-on": "#fff", "--ly-off": "rgba(255,255,255,.4)" }}>
      <div style={{ font: "600 22px/1.3 var(--font-display)" }}>{ln ? (ln.words ? <KaraokeLine line={ln} offset={off} /> : ln.text) : "Instrumental"}</div>
      {translation && ln?.tr && <div style={{ color: "rgba(255,255,255,.6)", marginTop: 4, fontSize: 15 }}>{ln.tr}</div>}
    </div>
  );
}

Object.assign(window, { Stage, STAGE_LAYOUTS, STAGE_BACKGROUNDS });
