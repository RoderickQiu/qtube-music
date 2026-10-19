// Desktop surface: QTube Music without its window — menu bar menus, menu-bar extra, mini player, desktop lyrics.

function controlsMenuItems(p, ui) {
  const s = p.state;
  return [
    { label: tr(s.playing ? "Pause" : "Play"), shortcut: "Space", onClick: p.toggle },
    { label: tr("Next"), shortcut: "⌘→", onClick: () => p.next() },
    { label: tr("Previous"), shortcut: "⌘←", onClick: p.prev },
    { sep: true },
    { label: tr(s.liked.has(s.trackId) ? "Remove from Liked Songs" : "Like"), shortcut: "⌘L", onClick: () => p.like() },
    { label: tr("Shuffle"), check: s.shuffle, onClick: p.setShuffle },
    { label: tr("Repeat"), check: s.repeat, onClick: p.setRepeat },
    { sep: true },
    { label: tr("Song ⇄ Music Video"), shortcut: "⇧⌘V", disabled: !p.track.mv, onClick: ui.toggleVideo },
    { label: tr("Stage"), shortcut: "⇧⌘F", onClick: ui.openStage },
    { label: tr("Mini Player"), shortcut: "⇧⌘M", onClick: ui.toggleMini },
    { label: tr("Desktop Lyrics"), check: ui.deskLyrics, shortcut: "⇧⌘L", onClick: ui.toggleDeskLyrics },
    { sep: true },
    { label: tr("Lyrics Earlier"), shortcut: "⌥↑", onClick: () => p.nudgeOffset(-0.1) },
    { label: tr("Lyrics Later"), shortcut: "⌥↓", onClick: () => p.nudgeOffset(0.1) },
  ];
}

function MenuBarExtra() {
  const p = usePlayer();
  const pos = usePosition(4);
  const [open, setOpen] = useState(true);
  const t = p.track;
  const ln = currentLyric(t, pos + p.state.lyricOffset);
  return (
    <>
      <button className={`mb-extra ${open ? "open" : ""}`} onClick={() => setOpen(!open)} title="QTube Music">
        <Icon name="note" size={14} />
        <span className="marquee">{t.title} — {t.artist}</span>
      </button>
      {open && (
        <div className="popover" onMouseDown={(e) => e.stopPropagation()}>
          <div className="mbp-top">
            <img src={t.cover} alt="" />
            <div className="mbp-meta">
              <div className="mbp-title">{t.title}</div>
              <div className="mbp-artist">{t.artist}</div>
            </div>
            <button className={`mbp-like ${p.state.liked.has(t.id) ? "on" : ""}`} onClick={() => p.like()} aria-label={tr("Like")}>
              <Icon name={p.state.liked.has(t.id) ? "heartFill" : "heart"} size={16} />
            </button>
          </div>
          <div className="mbp-scrub"><Scrubber /></div>
          <div className="mbp-controls">
            <button className="tp" onClick={p.prev} aria-label={tr("Previous")}><Icon name="prev" size={18} /></button>
            <button className="tp mbp-play" onClick={p.toggle} aria-label={tr(p.state.playing ? "Pause" : "Play")}><Icon name={p.state.playing ? "pause" : "play"} size={18} /></button>
            <button className="tp" onClick={() => p.next()} aria-label={tr("Next")}><Icon name="next" size={18} /></button>
          </div>
          {!p.state.ad && ln && (
            <div className="mbp-lyric">
              {ln.text}
              {ln.tr && <small>{ln.tr}</small>}
            </div>
          )}
        </div>
      )}
    </>
  );
}

function MiniPlayer() {
  const p = usePlayer();
  const pos = usePosition(4);
  const [mode, setMode] = useState("compact");
  const t = p.track;
  const pct = p.state.ad ? 0 : (pos / t.duration) * 100;
  const controls = (
    <div style={{ display: "flex", gap: 14, alignItems: "center" }}>
      <button className="tp" onClick={p.prev}><Icon name="prev" size={15} /></button>
      <button className="tp" onClick={p.toggle}><Icon name={p.state.playing ? "pause" : "play"} size={18} /></button>
      <button className="tp" onClick={() => p.next()}><Icon name="next" size={15} /></button>
    </div>
  );
  return (
    <div className={`mini ${mode}`} onDoubleClick={() => setMode(mode === "compact" ? "art" : "compact")} title={tr("Double-click to switch size")}>
      <img src={t.cover} alt="" />
      {mode === "compact" ? (
        <>
          <div style={{ minWidth: 0 }}>
            <div className="t-title" style={{ color: "#fff" }}>{p.state.ad ? tr("Advertisement") : t.title}</div>
            <div className="t-sub" style={{ color: "rgba(255,255,255,.6)" }}>{t.artist}</div>
          </div>
          {controls}
        </>
      ) : (
        <div className="mini-hover">
          <div className="t-title" style={{ color: "#fff", fontWeight: 600 }}>{t.title}</div>
          <div className="t-sub" style={{ color: "rgba(255,255,255,.7)", marginBottom: 10 }}>{t.artist}</div>
          {controls}
        </div>
      )}
      <div className="line" style={{ width: `${pct}%` }} />
    </div>
  );
}

function DesktopLyrics({ translation }) {
  const p = usePlayer();
  const pos = usePosition(10);
  const off = p.state.lyricOffset;
  const t = p.track;
  if (p.state.ad) return null;
  const ln = currentLyric(t, pos + off);
  if (!ln) return null;
  return (
    <div className="desk-lyrics">
      <div className="dl-main">{ln.words ? <KaraokeLine line={ln} offset={off} /> : ln.text}</div>
      {translation && ln.tr && <div className="dl-tr">{ln.tr}</div>}
    </div>
  );
}

function DesktopSurface({ translation, ui }) {
  const p = usePlayer();
  const [menu, setMenu] = useState(null);
  const appMenus = ["File", "Edit", "Controls", "View", "Window", "Help"];
  return (
    <div className="desktop theme-dark">
      <div className="dwall" style={{ backgroundImage: `url(${p.track.cover})` }} />
      <div className="menubar">
        <span style={{ fontSize: 15 }}></span>
        <span className="app">QTube Music</span>
        {appMenus.map((m) => (
          <span key={m} style={{ padding: "0 2px", cursor: "default", borderRadius: 4, background: menu?.name === m ? "rgba(255,255,255,.2)" : "none" }}
            onClick={(e) => m === "Controls" ? setMenu({ name: m, x: e.clientX - 10, y: e.clientY + 14 }) : ui.toast(tr("Not in this prototype yet"))}>
            {tr(m)}
          </span>
        ))}
        <div className="right">
          <MenuBarExtra />
          <span>{formatClock()}</span>
        </div>
      </div>
      {ui.deskLyrics && <DesktopLyrics translation={translation} />}
      <MiniPlayer />
      {menu && <NativeMenu x={menu.x} y={menu.y} theme="dark" items={controlsMenuItems(p, ui)} onClose={() => setMenu(null)} />}
    </div>
  );
}

Object.assign(window, { DesktopSurface, controlsMenuItems });
