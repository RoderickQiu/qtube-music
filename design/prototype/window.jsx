// Main window: source-list sidebar, Liked Songs table, docked Now Playing panel, player bar.

const USER_PLAYLISTS = ["Sugar", "你喜欢的歌曲重新上架", "2025 Sel 1", "rodrii的2024年度歌单", "2024 Sel 1", "@rodrii的十年精选辑", "rodrii的2022年度歌单"];

const foldKey = (s) => s.normalize("NFKD").replace(/[̀-ͯ]/g, "").replace(/[đĐ]/g, "d").toLowerCase();
const letterOf = (s) => { const c = foldKey(s)[0]?.toUpperCase(); return c && c >= "A" && c <= "Z" ? c : "#"; };

function Sidebar({ section, setSection, onDropToPlaylist, toast }) {
  const [over, setOver] = useState(null);
  const item = (id, icon, label) => (
    <div className={`sb-item ${section === id ? "active" : ""}`} onClick={() => (["home", "liked"].includes(id) ? setSection(id) : toast("Not in this prototype yet"))}>
      <Icon name={icon} size={15} /> {label}
    </div>
  );
  return (
    <aside className="sidebar">
      {item("home", "home", "Home")}
      {item("explore", "compass", "Explore")}
      <div className="sb-section">Library</div>
      {item("songs", "note", "Songs")}
      {item("albums", "album", "Albums")}
      {item("artists", "mic", "Artists")}
      {item("liked", "heart", "Liked Songs")}
      {item("history", "clock", "History")}
      <div className="sb-section">Playlists</div>
      {USER_PLAYLISTS.map((name) => (
        <div key={name} className={`sb-item ${over === name ? "drop" : ""}`}
          onDragOver={(e) => { e.preventDefault(); setOver(name); }} onDragLeave={() => setOver(null)}
          onDrop={(e) => { e.preventDefault(); setOver(null); onDropToPlaylist(e.dataTransfer.getData("text/plain"), name); }}
          onClick={() => toast("Not in this prototype yet")}>
          <Icon name="playlist" size={15} /> {name}
        </div>
      ))}
    </aside>
  );
}

function LibraryView({ theme, selected, setSelected, toast, onShowVideo, filterRef }) {
  const p = usePlayer();
  const [sort, setSort] = useState({ key: "added", dir: 1 });
  const [query, setQuery] = useState("");
  const [menu, setMenu] = useState(null);
  const [compact, setCompact] = useState(false);
  const tableRef = useRef(null);
  const headRef = useRef(null);
  const rows = useMemo(() => {
    const q = foldKey(query);
    let r = TRACKS.filter((t) => !q || foldKey(`${t.title} ${t.artist} ${t.album} ${t.subtitle || ""}`).includes(q));
    if (sort.key !== "added") {
      const get = { title: (t) => foldKey(t.title), album: (t) => foldKey(t.album), time: (t) => t.duration }[sort.key];
      r = [...r].sort((a, b) => (get(a) > get(b) ? 1 : get(a) < get(b) ? -1 : 0) * sort.dir);
    }
    return r;
  }, [sort, query]);
  const total = TRACKS.reduce((n, t) => n + t.duration, 0);
  const letters = new Set(rows.map((t) => letterOf(t.title)));
  const sortBy = (key) => setSort((s) => ({ key, dir: s.key === key ? -s.dir : 1 }));
  const arrow = (key) => (sort.key === key ? <Icon name={sort.dir > 0 ? "chevU" : "chevD"} size={10} stroke={2.4} /> : null);
  const jump = (L) => {
    const i = rows.findIndex((t) => letterOf(t.title) === L);
    if (i < 0) return;
    const el = tableRef.current.querySelectorAll(".t-row:not(.header)")[i];
    tableRef.current.parentElement.scrollTo({ top: el.offsetTop + tableRef.current.offsetTop - 40, behavior: "smooth" });
    setSelected(rows[i].id);
  };
  const openMenu = (e, t) => {
    e.preventDefault();
    setSelected(t.id);
    setMenu({
      x: e.clientX, y: e.clientY,
      items: [
        { label: "Play", shortcut: "↩", onClick: () => p.play(t.id), disabled: t.unavailable },
        { label: "Play Next", shortcut: "⌥↩", onClick: () => { p.playNext(t.id); toast(`“${t.title}” will play next`); }, disabled: t.unavailable },
        { label: "Add to Queue", onClick: () => { p.addToQueue(t.id); toast("Added to Up Next"); }, disabled: t.unavailable },
        { sep: true },
        { label: t.mv ? "Play Music Video" : "No Music Video", shortcut: t.mv ? "⇧⌘V" : null, disabled: !t.mv || t.unavailable, onClick: () => { p.play(t.id); onShowVideo(); } },
        { label: `Go to Album · ${t.album}` },
        { label: `Go to Artist · ${t.artist}` },
        { sep: true },
        { label: "Add to Playlist", shortcut: "▸" },
        { label: p.state.liked.has(t.id) ? "Remove from Liked Songs" : "Like", shortcut: "⌘L", onClick: () => p.like(t.id) },
        { sep: true },
        { label: "Copy Link", shortcut: "⌘C", onClick: () => toast("Link copied") },
      ],
    });
  };
  useEffect(() => {
    const onKey = (e) => {
      if (e.target.tagName === "INPUT") return;
      if (e.key === "Enter" && selected) { e.preventDefault(); e.altKey ? p.playNext(selected) : p.play(selected); }
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault();
        const i = rows.findIndex((t) => t.id === selected);
        const n = rows[Math.max(0, Math.min(rows.length - 1, i + (e.key === "ArrowDown" ? 1 : -1)))];
        if (n) setSelected(n.id);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [rows, selected]);

  const playAll = () => p.play(rows.find((t) => !t.unavailable).id);
  const shuffleAll = () => { if (!p.state.shuffle) p.setShuffle(); p.play(rows[Math.floor(Math.random() * rows.length)].id); };
  const onScroll = (e) => setCompact(e.currentTarget.scrollTop > (headRef.current?.offsetHeight || 200) - 64);

  return (
    <div className="content" onScroll={onScroll}>
      <div className={`lib-compact ${compact ? "show" : ""}`} aria-hidden={!compact}>
        <div className="lib-tile tiny"><Icon name="heartFill" size={14} stroke={0} /></div>
        <b>Liked Songs</b>
        <button className="icon-ghost panel" title="Play" onClick={playAll}><Icon name="play" size={14} /></button>
        <button className="icon-ghost panel" title="Shuffle" onClick={shuffleAll}><Icon name="shuffle" size={15} /></button>
        <span style={{ flex: 1 }} />
        <div className="filter-wrap">
          <Icon name="search" size={14} />
          <input className="filter" placeholder="Filter  ⌘F" value={query} onChange={(e) => setQuery(e.target.value)} />
        </div>
      </div>
      <div className="lib-head" ref={headRef}>
        <div className="lib-tile"><Icon name="heartFill" size={56} stroke={0} /></div>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div className="lib-meta" style={{ fontSize: 11, fontWeight: 600 }}>PLAYLIST</div>
          <div className="lib-title">Liked Songs</div>
          <div className="lib-meta">{TRACKS.length} songs · {Math.round(total / 60)} min</div>
          <div className="lib-actions">
            <button className="pill-btn primary" onClick={playAll}><Icon name="play" size={12} /> Play</button>
            <button className="pill-btn" onClick={shuffleAll}><Icon name="shuffle" size={13} /> Shuffle</button>
            <button className="pill-btn" title="More"><Icon name="more" size={14} /></button>
          </div>
        </div>
        <div className="filter-wrap">
          <Icon name="search" size={14} />
          <input ref={filterRef} className="filter" placeholder="Filter Liked Songs  ⌘F" value={query} onChange={(e) => setQuery(e.target.value)} />
        </div>
      </div>
      <div className="table" ref={tableRef}>
        <div className={`t-row header ${compact ? "pinned" : ""}`}>
          <button onClick={() => setSort({ key: "added", dir: 1 })} style={{ justifyContent: "center" }}>#</button>
          <button className={sort.key === "title" ? "on" : ""} onClick={() => sortBy("title")}>Title {arrow("title")}</button>
          <button className={sort.key === "album" ? "on" : ""} onClick={() => sortBy("album")}>Album {arrow("album")}</button>
          <span />
          <button className={sort.key === "time" ? "on" : ""} onClick={() => sortBy("time")} style={{ justifyContent: "flex-end" }}>{arrow("time")} Time</button>
        </div>
        {rows.map((t, i) => {
          const playing = p.state.trackId === t.id;
          return (
            <div key={t.id} draggable={!t.unavailable}
              onDragStart={(e) => e.dataTransfer.setData("text/plain", t.id)}
              className={`t-row ${selected === t.id ? "selected" : ""} ${playing ? "playing" : ""} ${t.unavailable ? "unavailable" : ""}`}
              onClick={() => setSelected(t.id)} onDoubleClick={() => p.play(t.id)} onContextMenu={(e) => openMenu(e, t)}
              title={t.unavailable ? "Not available in your region" : undefined}>
              <span className="t-num">{playing ? <Icon name={p.state.playing ? "volume" : "pause"} size={13} style={{ color: "var(--accent)" }} /> : i + 1}</span>
              <div className="t-titlecell">
                <img src={t.cover} alt="" />
                <div style={{ minWidth: 0 }}>
                  <div className="t-title">{t.title}{t.subtitle ? <span style={{ color: "var(--fg-3)", fontWeight: 400 }}> ({t.subtitle})</span> : null}</div>
                  <div className="t-sub">{t.mv && <span className="badge">MV</span>}{t.lyrics?.wordSynced && <span className="badge">Word lyrics</span>}{t.artist}</div>
                </div>
              </div>
              <span className="t-album">{t.album}</span>
              <button className={`heart ${p.state.liked.has(t.id) ? "on" : ""}`} onClick={(e) => { e.stopPropagation(); p.like(t.id); }}>
                <Icon name={p.state.liked.has(t.id) ? "heartFill" : "heart"} size={15} />
              </button>
              <span className="t-time">{fmt(t.duration)}</span>
            </div>
          );
        })}
        {!rows.length && <div className="empty-note">No songs match “{query}”.</div>}
        <div className="az" aria-label="Jump to letter">
          {"ABCDEFGHIJKLMNOPQRSTUVWXYZ#".split("").map((L) => (
            <span key={L} onClick={() => jump(L)} style={{ cursor: letters.has(L) ? "pointer" : "default" }}>{letters.has(L) ? <b>{L}</b> : L}</span>
          ))}
        </div>
      </div>
      {menu && <NativeMenu {...menu} theme={theme} onClose={() => setMenu(null)} />}
    </div>
  );
}

function SongVideoToggle({ videoMode, setVideoMode, track }) {
  return (
    <div className="seg" role="tablist" title={track.mv ? "Switch between the song and its official music video (⇧⌘V)" : "No official music video for this song"}>
      <button className={!videoMode ? "on" : ""} onClick={() => setVideoMode(false)}>Song</button>
      <button className={videoMode && track.mv ? "on" : ""} disabled={!track.mv} onClick={() => setVideoMode(true)}>Video</button>
    </div>
  );
}

function UpNext({ toast }) {
  const p = usePlayer();
  const s = p.state;
  const row = (id, cls = "") => {
    const t = byId[id];
    return (
      <div key={id + cls} className={`q-row ${cls}`} onDoubleClick={() => p.play(id)}>
        <img src={t.cover} alt="" />
        <div style={{ minWidth: 0 }}>
          <div className="t-title">{t.title}</div>
          <div className="t-sub">{t.artist}</div>
        </div>
        <span className="grip"><Icon name="grip" size={14} /></span>
      </div>
    );
  };
  return (
    <div className="queue">
      <div className="q-head">Now Playing</div>
      {row(s.trackId, "now")}
      <div className="q-head">
        Up Next
        {s.upNext.length > 0 && <button onClick={() => { const undo = p.clearUpNext(); toast("Cleared Up Next", undo); }}>Clear</button>}
      </div>
      {s.upNext.length ? s.upNext.map((id) => row(id)) : <div className="q-empty">Nothing queued</div>}
      <div className="q-head">Autoplay</div>
      {p.autoplay().slice(0, 6).map((t) => row(t.id, "auto"))}
    </div>
  );
}

// Docked inspector: what's playing (with lyrics) and the queue. Playback controls live only in the player bar.
function NowPlayingPanel({ collapsed, setCollapsed, tab, setTab, videoMode, setVideoMode, onOpenStage, theme, translation, setTranslation, toast }) {
  const p = usePlayer();
  const t = p.track;
  const showVideo = videoMode && t.mv;
  return (
    <aside className={`np-panel ${collapsed ? "collapsed" : ""}`} aria-hidden={collapsed}>
      <div className="np-backdrop" style={{ backgroundImage: `url(${t.cover})` }} />
      <div className="np-head">
        <div className="seg np-seg" role="tablist">
          {["Now Playing", "Queue"].map((x) => (
            <button key={x} role="tab" className={tab === x ? "on" : ""} onClick={() => setTab(x)}>{x}</button>
          ))}
        </div>
        <button className="icon-ghost panel" title="Hide panel  ⌥⌘N" aria-label="Hide panel" onClick={() => setCollapsed(true)}><Icon name="sidebar" size={16} /></button>
      </div>
      <div className="np-body">
        {tab === "Now Playing" && (
          <>
            <div className={`np-hero ${showVideo ? "video" : ""}`}>
              {p.state.ad ? <AdCard size={88} /> : (
                <img className="np-thumb" src={showVideo ? t.mv.still : t.cover} alt="" onClick={onOpenStage} title="Open Stage  ⇧⌘F" />
              )}
              <div className="np-hero-meta">
                <div className="np-title">{t.title}</div>
                <div className="np-artist">{t.artist}</div>
                <div className="np-hero-actions">
                  <SongVideoToggle videoMode={videoMode} setVideoMode={setVideoMode} track={t} />
                  <LyricsOptionsButton track={t} theme={theme} translation={translation} setTranslation={setTranslation} onToast={toast} className="icon-ghost panel" />
                </div>
              </div>
            </div>
            <div className="np-lyrics-body"><LyricsView track={t} mode="panel" translation={translation} anchor={0.34} /></div>
          </>
        )}
        {tab === "Queue" && <UpNext toast={toast} />}
      </div>
    </aside>
  );
}

function PlayerBar({ onOpenStage, onMini, panelCollapsed, togglePanel, openTab }) {
  const p = usePlayer();
  const t = p.track;
  return (
    <footer className="playerbar">
      <div className="pb-now">
        <img src={t.cover} alt="" onClick={onOpenStage} title="Open Stage (⌘⇧F)" />
        <div style={{ minWidth: 0 }}>
          <div className="t-title">{p.state.ad ? "Advertisement" : t.title}</div>
          <div className="t-sub">{p.state.ad ? `Then: ${t.title}` : t.artist}</div>
        </div>
        <button className={`heart ${p.state.liked.has(t.id) ? "on" : ""}`} onClick={() => p.like()} title="Like (⌘L)">
          <Icon name={p.state.liked.has(t.id) ? "heartFill" : "heart"} size={16} />
        </button>
      </div>
      <div className="pb-center">
        <div className="pb-transport"><Transport size={15} playSize={14} /></div>
        <Scrubber />
      </div>
      <div className="pb-right">
        <button className="tb-btn" title="Lyrics" onClick={() => openTab("Now Playing")}><Icon name="lyrics" size={16} /></button>
        <button className="tb-btn" title="Queue" onClick={() => openTab("Queue")}><Icon name="list" size={16} /></button>
        <button className="tb-btn" title="AirPlay"><Icon name="airplay" size={16} /></button>
        <Icon name="volume" size={16} />
        <div className="track vol"><div className="fill" style={{ width: "70%" }} /></div>
        <button className="tb-btn" title="Mini player (⌘⇧M)" onClick={onMini}><Icon name="mini" size={16} /></button>
        <button className="tb-btn" title="Stage (⌘⇧F)" onClick={onOpenStage}><Icon name="expand" size={16} /></button>
      </div>
    </footer>
  );
}

Object.assign(window, { USER_PLAYLISTS, Sidebar, LibraryView, NowPlayingPanel, PlayerBar, SongVideoToggle, UpNext });
