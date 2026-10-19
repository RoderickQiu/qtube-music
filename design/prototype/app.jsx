// App shell: surfaces, tweaks, keyboard shortcuts, artwork-driven colour, scale-to-fit.

const TWEAK_KEY = "qtube-tweaks-v1";
// URL params override saved tweaks, e.g. ?surface=stage&stageBackground=vinyl (shareable states).
const loadTweaks = () => {
  let saved = {};
  try { saved = JSON.parse(localStorage.getItem(TWEAK_KEY) || "{}"); } catch {}
  const url = Object.fromEntries(new URLSearchParams(location.search));
  if (url.translation) url.translation = url.translation !== "false";
  return { ...window.QT_TWEAK_DEFAULTS, ...saved, ...url };
};

function useFitScale() {
  const calc = () => Math.min((innerWidth - 32) / 1440, (innerHeight - 32) / 900, 1.35);
  const [s, setS] = useState(calc);
  useEffect(() => { const f = () => setS(calc()); addEventListener("resize", f); return () => removeEventListener("resize", f); }, []);
  return s;
}

function TweaksPanel({ tw, set, open, setOpen }) {
  const p = usePlayer();
  if (!open) return <button className="tweaks-fab" onClick={() => setOpen(true)}>Tweaks</button>;
  const row = (label, key, opts) => (
    <div className="tw-row">
      <label>{label}</label>
      <div className="tw-opts">
        {opts.map(([v, l]) => <button key={String(v)} className={tw[key] === v ? "on" : ""} onClick={() => set(key, v)}>{l}</button>)}
      </div>
    </div>
  );
  return (
    <div className="tweaks" onKeyDown={(e) => e.stopPropagation()}>
      <h4>Tweaks <button onClick={() => setOpen(false)}><Icon name="close" size={12} /></button></h4>
      {row("Surface", "surface", [["window", "Window"], ["stage", "Stage"], ["desktop", "Mini + menu bar"]])}
      {row("Stage layout", "stageLayout", STAGE_LAYOUTS.map((x) => [x.id, x.label.split(" —")[0]]))}
      {row("Stage background", "stageBackground", STAGE_BACKGROUNDS.map((x) => [x.id, x.label.replace(" (Premium)", "")]))}
      {row("Account", "account", [["premium", "Premium engine"], ["free", "Free (ads)"]])}
      {tw.account === "free" && <div className="tw-row"><div className="tw-opts"><button onClick={() => p.playAd()}>Play an ad now</button></div></div>}
      {row("Window theme", "theme", [["dark", "Dark"], ["light", "Light"]])}
      {row("Translation line", "translation", [[true, "On"], [false, "Off"]])}
    </div>
  );
}

function App() {
  const p = usePlayer();
  const scale = useFitScale();
  const [tw, setTw] = useState(loadTweaks);
  const [tweaksOpen, setTweaksOpen] = useState(false);
  const [section, setSection] = useState(new URLSearchParams(location.search).get("section") || "home");
  const [selected, setSelected] = useState(TRACKS[0].id);
  const [panelCollapsed, setPanelCollapsed] = useState(false);
  const [tab, setTab] = useState("Now Playing");
  const [videoMode, setVideoMode] = useState(tw.stageBackground === "video");
  const [deskLyrics, setDeskLyrics] = useState(true);
  const [toastMsg, setToastMsg] = useState(null);
  const filterRef = useRef(null);
  const toastTimer = useRef(null);
  const t = p.track;

  const toast = useCallback((msg, undo) => {
    clearTimeout(toastTimer.current);
    setToastMsg({ msg, undo });
    toastTimer.current = setTimeout(() => setToastMsg(null), undo ? 5000 : 2200);
  }, []);

  const set = useCallback((key, value) => {
    setTw((prev) => {
      const next = { ...prev, [key]: value };
      localStorage.setItem(TWEAK_KEY, JSON.stringify(next));
      window.parent?.postMessage({ type: "__edit_mode_set_keys", edits: { [key]: value } }, "*");
      return next;
    });
    if (key === "account") player.setAccount(value);
    if (key === "stageBackground") setVideoMode(value === "video");
  }, []);

  // Host Tweaks protocol: listener first, then announce.
  useEffect(() => {
    const onMsg = (e) => {
      if (e.data?.type === "__activate_edit_mode") setTweaksOpen(true);
      if (e.data?.type === "__deactivate_edit_mode") setTweaksOpen(false);
    };
    addEventListener("message", onMsg);
    window.parent?.postMessage({ type: "__edit_mode_available" }, "*");
    player.setAccount(tw.account);
    return () => removeEventListener("message", onMsg);
  }, []);

  // Artwork-driven colour.
  useEffect(() => {
    document.documentElement.style.setProperty("--art", t.colors.accent);
    document.documentElement.style.setProperty("--art-deep", t.colors.deep);
  }, [t.id]);

  // Video mode only exists for tracks with an official MV.
  useEffect(() => { if (!t.mv && videoMode) setVideoMode(false); }, [t.id]);

  const ui = {
    toast,
    deskLyrics,
    toggleDeskLyrics: () => setDeskLyrics((x) => !x),
    toggleVideo: () => t.mv && setVideoMode((x) => !x),
    openStage: () => set("surface", "stage"),
    toggleMini: () => set("surface", tw.surface === "desktop" ? "window" : "desktop"),
  };

  useEffect(() => {
    const onKey = (e) => {
      const typing = e.target.tagName === "INPUT";
      const cmd = e.metaKey || e.ctrlKey;
      if (e.key === " " && !typing) { e.preventDefault(); p.toggle(); }
      else if (cmd && e.key === "ArrowRight") { e.preventDefault(); p.next(); }
      else if (cmd && e.key === "ArrowLeft") { e.preventDefault(); p.prev(); }
      else if (cmd && !e.shiftKey && e.key.toLowerCase() === "l") { e.preventDefault(); p.like(); toast(p.state.liked.has(p.state.trackId) ? "Added to Liked Songs" : "Removed from Liked Songs"); }
      else if (cmd && !e.shiftKey && e.key.toLowerCase() === "f") { e.preventDefault(); set("surface", "window"); setSection("liked"); setTimeout(() => filterRef.current?.focus(), 50); }
      else if (cmd && e.shiftKey && e.key.toLowerCase() === "f") { e.preventDefault(); set("surface", tw.surface === "stage" ? "window" : "stage"); }
      else if (cmd && e.shiftKey && e.key.toLowerCase() === "v") { e.preventDefault(); if (t.mv) setVideoMode((x) => !x); else toast("No official music video for this song"); }
      else if (cmd && e.shiftKey && e.key.toLowerCase() === "m") { e.preventDefault(); ui.toggleMini(); }
      else if (cmd && e.shiftKey && e.key.toLowerCase() === "l") { e.preventDefault(); setDeskLyrics((x) => !x); }
      else if (cmd && e.altKey && e.key.toLowerCase() === "n") { e.preventDefault(); setPanelCollapsed((x) => !x); }
      else if (e.altKey && (e.key === "ArrowUp" || e.key === "ArrowDown")) {
        e.preventDefault();
        p.nudgeOffset(e.key === "ArrowUp" ? -0.1 : 0.1);
        const o = player.state.lyricOffset;
        toast(`Lyrics timing ${o >= 0 ? "+" : ""}${o.toFixed(1)} s · saved for this song`);
      }
    };
    addEventListener("keydown", onKey);
    return () => removeEventListener("keydown", onKey);
  }, [tw.surface, t.id]);

  const theme = tw.theme;
  const stageOpen = tw.surface === "stage";

  return (
    <div className="viewport">
      <div className="wallpaper" style={{ backgroundImage: `url(${t.cover})` }} />
      <div className="scaler" style={{ transform: `translate(-50%, -50%) scale(${scale})` }}>
        {tw.surface === "desktop" ? (
          <DesktopSurface translation={tw.translation} ui={ui} />
        ) : (
          <div className={`mac-window theme-${theme}`}>
            <div className="traffic"><i /><i /><i /></div>
            <Sidebar section={section} setSection={setSection} toast={toast}
              onDropToPlaylist={(id, name) => id && toast(`Added “${byId[id].title}” to ${name}`)} />
            <main className="main">
              <div className="toolbar">
                <button className="tb-btn" title="Back"><Icon name="chevL" size={16} /></button>
                <button className="tb-btn" title="Forward"><Icon name="chevR" size={16} /></button>
                <div className="search"><Icon name="search" size={14} /> Search music <span style={{ flex: 1 }} /><kbd>⌘K</kbd></div>
                <span style={{ flex: 1 }} />
                {panelCollapsed && (
                  <button className="tb-btn" title="Show panel  ⌥⌘N" aria-label="Show panel" onClick={() => setPanelCollapsed(false)}><Icon name="sidebar" size={16} /></button>
                )}
              </div>
              {section === "home" ? (
                <HomeView onShowVideo={() => setVideoMode(true)} onOpenPlaylist={() => setSection("liked")} />
              ) : (
                <LibraryView theme={theme} selected={selected} setSelected={setSelected} toast={toast}
                  onShowVideo={() => setVideoMode(true)} filterRef={filterRef} />
              )}
            </main>
            <NowPlayingPanel collapsed={panelCollapsed} setCollapsed={setPanelCollapsed} tab={tab} setTab={setTab} videoMode={videoMode} setVideoMode={setVideoMode}
              onOpenStage={ui.openStage} theme={theme} translation={tw.translation} setTranslation={(v) => set("translation", v)} toast={toast} />
            <PlayerBar onOpenStage={ui.openStage} onMini={ui.toggleMini} panelCollapsed={panelCollapsed}
              togglePanel={() => setPanelCollapsed((x) => !x)} openTab={(x) => { setPanelCollapsed(false); setTab(x); }} />
            {stageOpen && (
              <Stage layout={tw.stageLayout} setLayout={(v) => set("stageLayout", v)}
                background={tw.stageBackground} setBackground={(v) => set("stageBackground", v)}
                videoMode={videoMode} setVideoMode={setVideoMode} onClose={() => set("surface", "window")}
                theme={theme} translation={tw.translation} setTranslation={(v) => set("translation", v)} toast={toast} />
            )}
          </div>
        )}
        {toastMsg && (
          <div className={`toast theme-${theme}`} style={{ pointerEvents: toastMsg.undo ? "auto" : "none" }}>
            {toastMsg.msg}
            {toastMsg.undo && <button style={{ marginLeft: 10, color: "var(--accent)", fontWeight: 600 }} onClick={() => { toastMsg.undo(); setToastMsg(null); }}>Undo</button>}
          </div>
        )}
      </div>
      <TweaksPanel tw={tw} set={set} open={tweaksOpen} setOpen={setTweaksOpen} />
    </div>
  );
}

ReactDOM.createRoot(document.getElementById("root")).render(<App />);
