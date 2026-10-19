// Home: built only from the user's real library — no invented recommendations.

const MOODS = ["Relax", "Energize", "Focus", "Commute", "Romance", "Sleep", "Feel good"];

function greeting() {
  const h = new Date().getHours();
  return h < 5 ? "Good night" : h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening";
}

function Shelf({ title, children, scroller = false }) {
  const ref = useRef(null);
  const by = (d) => ref.current?.scrollBy({ left: d * ref.current.clientWidth * 0.8, behavior: "smooth" });
  return (
    <section className="shelf">
      <header>
        <h2>{title}</h2>
        {scroller && (
          <div className="shelf-nav">
            <button className="icon-ghost panel" aria-label="Scroll left" onClick={() => by(-1)}><Icon name="chevL" size={16} /></button>
            <button className="icon-ghost panel" aria-label="Scroll right" onClick={() => by(1)}><Icon name="chevR" size={16} /></button>
          </div>
        )}
      </header>
      <div className={scroller ? "shelf-row" : undefined} ref={ref}>{children}</div>
    </section>
  );
}

function HomeView({ onShowVideo, onOpenPlaylist }) {
  const p = usePlayer();
  const playable = TRACKS.filter((t) => !t.unavailable);
  const withVideo = playable.filter((t) => t.mv);
  return (
    <div className="content home">
      <div className="home-head">
        <h1>{greeting()}</h1>
        <div className="chips">{MOODS.map((m) => <button key={m} className="chip">{m}</button>)}</div>
      </div>

      <Shelf title="Listen again" scroller>
        {playable.map((t) => (
          <button key={t.id} className={`card ${p.state.trackId === t.id ? "playing" : ""}`} onClick={() => p.play(t.id)}>
            <div className="card-art">
              <img src={t.cover} alt="" />
              <span className="card-play"><Icon name={p.state.trackId === t.id && p.state.playing ? "pause" : "play"} size={16} /></span>
            </div>
            <div className="t-title">{t.title}</div>
            <div className="t-sub">{t.artist}</div>
          </button>
        ))}
      </Shelf>

      <Shelf title="Quick picks">
        <div className="picks">
          {playable.slice(0, 9).map((t) => (
            <div key={t.id} className={`pick ${p.state.trackId === t.id ? "playing" : ""}`} onDoubleClick={() => p.play(t.id)}>
              <button className="pick-art" onClick={() => p.play(t.id)} aria-label={`Play ${t.title}`}>
                <img src={t.cover} alt="" /><span><Icon name="play" size={12} /></span>
              </button>
              <div style={{ minWidth: 0 }}>
                <div className="t-title">{t.title}</div>
                <div className="t-sub">{t.artist}</div>
              </div>
              <button className={`heart ${p.state.liked.has(t.id) ? "on" : ""}`} onClick={() => p.like(t.id)} aria-label="Like">
                <Icon name={p.state.liked.has(t.id) ? "heartFill" : "heart"} size={15} />
              </button>
            </div>
          ))}
        </div>
      </Shelf>

      <Shelf title="Music videos" scroller>
        {withVideo.map((t) => (
          <button key={t.id} className="vcard" onClick={() => { p.play(t.id); onShowVideo(); }}>
            <div className="vcard-art">
              <img src={t.mv.still} alt="" />
              <span className="card-play"><Icon name="play" size={16} /></span>
            </div>
            <div className="t-title">{t.title}</div>
            <div className="t-sub">{t.artist}</div>
          </button>
        ))}
      </Shelf>

      <Shelf title="Your playlists" scroller>
        <button className="card" onClick={onOpenPlaylist}>
          <div className="card-art liked"><Icon name="heartFill" size={44} stroke={0} /></div>
          <div className="t-title">Liked Songs</div>
          <div className="t-sub">{TRACKS.length} songs</div>
        </button>
        {USER_PLAYLISTS.map((name) => (
          <button key={name} className="card">
            <div className="card-art ph"><Icon name="playlist" size={34} /></div>
            <div className="t-title">{name}</div>
            <div className="t-sub">Playlist</div>
          </button>
        ))}
      </Shelf>
    </div>
  );
}

Object.assign(window, { HomeView });
