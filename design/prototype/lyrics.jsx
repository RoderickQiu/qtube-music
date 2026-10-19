// Lyrics renderer + shared native-style menu.
// Only the current line subscribes to the fast clock; everything else re-renders on line changes.

function NativeMenu({ x, y, items, onClose, theme }) {
  const ref = useRef(null);
  const [pos, setPos] = useState({ left: x, top: y });
  React.useLayoutEffect(() => {
    const r = ref.current.getBoundingClientRect();
    setPos({ left: Math.min(x, innerWidth - r.width - 8), top: Math.min(y, innerHeight - r.height - 8) });
  }, [x, y]);
  useEffect(() => {
    const close = (e) => { if (!ref.current?.contains(e.target)) onClose(); };
    const esc = (e) => e.key === "Escape" && onClose();
    setTimeout(() => window.addEventListener("mousedown", close), 0);
    window.addEventListener("keydown", esc);
    return () => { window.removeEventListener("mousedown", close); window.removeEventListener("keydown", esc); };
  }, [onClose]);
  return ReactDOM.createPortal(
    <div className={`theme-${theme}`} style={{ position: "fixed", inset: 0, pointerEvents: "none", zIndex: 300 }}>
      <div className="menu" ref={ref} style={{ ...pos, pointerEvents: "auto" }} role="menu">
        {items.map((it, i) =>
          it.sep ? <div key={i} className="sep" /> :
          it.header ? <div key={i} className="mh">{it.header}</div> :
          <div key={i} role="menuitem" className={`mi ${it.disabled ? "disabled" : ""}`}
            onMouseUp={() => { if (!it.disabled) { it.onClick?.(); onClose(); } }}>
            {it.check !== undefined && <span className="check">{it.check ? "✓" : ""}</span>}
            <span>{it.label}</span>
            {it.shortcut && <span className="sc">{it.shortcut}</span>}
          </div>
        )}
      </div>
    </div>,
    document.body
  );
}

// Lyric providers, mirroring the researched chain (docs/redesign-draft.md §6).
const LYRIC_PROVIDERS = [
  { id: "ytm", name: "YouTube Music", tier: "safe" },
  { id: "lrclib", name: "LRCLIB", tier: "safe" },
  { id: "amll", name: "AMLL (word-synced)", tier: "safe" },
  { id: "netease", name: "NetEase", tier: "community" },
  { id: "kugou", name: "Kugou", tier: "community" },
  { id: "qq", name: "QQ Music", tier: "community" },
];

function lyricLineIndex(lines, t) {
  let lo = 0, hi = lines.length - 1, ans = -1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if (lines[mid].t <= t) { ans = mid; lo = mid + 1; } else hi = mid - 1;
  }
  return ans;
}

function KaraokeLine({ line, offset }) {
  const pos = usePosition(30);
  const t = pos + offset;
  return line.words.map((w, i) => {
    const p = Math.max(0, Math.min(1, (t - w.t) / Math.max(w.d, 0.05)));
    return <span key={i} className={`ly-word ${p >= 1 ? "done" : ""}`} style={{ "--p": p }}>{w.w}</span>;
  });
}

function LyricsView({ track, mode = "panel", align = "left", translation = true, anchor = 0.36 }) {
  const p = usePlayer();
  const pos = usePosition(10);
  const offset = p.state.lyricOffset;
  const lines = track.lyrics?.lines;
  const idx = lines ? lyricLineIndex(lines, pos + offset) : -1;
  const boxRef = useRef(null);
  const railRef = useRef(null);
  const [y, setY] = useState(0);            // follow position (current line at anchor)
  const [scrollY, setScrollY] = useState(null); // manual position while the user browses
  const resumeTimer = useRef(null);

  React.useLayoutEffect(() => {
    if (!lines || !railRef.current || !boxRef.current) return;
    const el = railRef.current.children[Math.max(0, idx)];
    if (!el) return;
    setY(boxRef.current.clientHeight * anchor - el.offsetTop - el.offsetHeight / 2);
  }, [idx, track.id, translation, mode, lines]);

  useEffect(() => { setScrollY(null); }, [track.id]);
  useEffect(() => () => clearTimeout(resumeTimer.current), []);

  const backToCurrent = () => { clearTimeout(resumeTimer.current); setScrollY(null); };
  const onWheel = (e) => {
    const box = boxRef.current, rail = railRef.current;
    if (!box || !rail) return;
    const h = box.clientHeight;
    const min = h * anchor - rail.scrollHeight, max = h * anchor;
    setScrollY((prev) => Math.max(min, Math.min(max, (prev ?? y) - e.deltaY)));
    clearTimeout(resumeTimer.current);
    resumeTimer.current = setTimeout(() => setScrollY(null), 6000);
  };

  if (p.state.ad && p.track.id === track.id) return null;
  if (!lines) return <div className="lyrics-empty">{tr("No lyrics")}</div>;
  const manual = scrollY !== null;
  return (
    <div className="lyrics-wrap" onWheel={onWheel}>
    <div className={`lyrics ly-${mode} ${align === "center" ? "center" : ""} ${manual ? "manual" : ""}`} ref={boxRef}>
      <div className="lyrics-rail" ref={railRef} style={{ transform: `translateY(${manual ? scrollY : y}px)` }}>
        {lines.map((ln, i) => {
          const state = i === idx ? "current" : i < idx ? "past" : "future";
          const far = mode === "stage" && !manual && Math.abs(i - idx) > 3 ? "far" : "";
          return (
            <div key={i} className={`ly-line ${state} ${far}`} onClick={() => { p.seek(ln.t - offset + 0.02); backToCurrent(); }}>
              <div className="ly-main">
                {i === idx && ln.words ? <KaraokeLine line={ln} offset={offset} /> : ln.text}
              </div>
              {translation && ln.tr && <div className="ly-tr">{ln.tr}</div>}
            </div>
          );
        })}
      </div>
    </div>
      {manual && (
        <button className="ly-back" onClick={backToCurrent} title={tr("Back to the current line")}>
          <Icon name={scrollY > y ? "chevD" : "chevU"} size={13} stroke={2.2} /> {tr("Current")}
        </button>
      )}
    </div>
  );
}

// Glass popover anchored under a button; closes on outside click or Esc.
function Popover({ anchor, onClose, children, width = 264, theme = "dark" }) {
  const ref = useRef(null);
  const r = anchor.getBoundingClientRect();
  const left = Math.max(8, Math.min(r.right - width, innerWidth - width - 8));
  const below = r.bottom + 8 + 260 < innerHeight;
  useEffect(() => {
    const close = (e) => { if (!ref.current?.contains(e.target) && !anchor.contains(e.target)) onClose(); };
    const esc = (e) => e.key === "Escape" && onClose();
    addEventListener("mousedown", close);
    addEventListener("keydown", esc);
    return () => { removeEventListener("mousedown", close); removeEventListener("keydown", esc); };
  }, [onClose]);
  const pos = below ? { top: r.bottom + 8 } : { bottom: innerHeight - r.top + 8 };
  return ReactDOM.createPortal(
    <div className={`theme-${theme} pop`} ref={ref} style={{ left, width, ...pos }}>{children}</div>,
    document.body
  );
}

const Switch = ({ on, onChange, label }) => (
  <button className={`switch ${on ? "on" : ""}`} role="switch" aria-checked={on} aria-label={label} onClick={() => onChange(!on)}><i /></button>
);

// Lyrics options behind one quiet icon: source, translation, unofficial sources, timing.
function LyricsOptionsButton({ track, translation, setTranslation, onToast, className = "icon-ghost", theme = "dark" }) {
  const p = usePlayer();
  const [anchor, setAnchor] = useState(null);
  const [unofficial, setUnofficial] = useState(true);
  const L = track.lyrics;
  const off = p.state.lyricOffset;
  return (
    <>
      <button className={className} title={tr("Lyrics")} aria-label={tr("Lyrics options")} onClick={(e) => setAnchor(anchor ? null : e.currentTarget)}>
        <Icon name="lyrics" size={16} />
      </button>
      {anchor && (
        <Popover anchor={anchor} theme={theme} onClose={() => setAnchor(null)}>
          <div className="pop-head">
            <b>{L ? tr(L.source.replace(/ \(.*\)/, "")) : tr("No lyrics")}</b>
            {L && <span>{tr(L.wordSynced ? "Word timing" : "Line timing")}</span>}
          </div>
          <div className="pop-row"><span>{tr("Translation")}</span><Switch on={translation} onChange={setTranslation} label={tr("Translation")} /></div>
          <div className="pop-row" title={tr("NetEase, Kugou and QQ Music — unofficial, may stop working")}>
            <span>{tr("Unofficial sources")}</span><Switch on={unofficial} onChange={setUnofficial} label={tr("Unofficial sources")} />
          </div>
          <div className="pop-row">
            <span>{tr("Timing")}</span>
            <div className="stepper">
              <button onClick={() => p.nudgeOffset(-0.1)} title={tk("Earlier", "⌥↑")}>−</button>
              <b>{off > 0 ? "+" : ""}{off.toFixed(1)}s</b>
              <button onClick={() => p.nudgeOffset(0.1)} title={tk("Later", "⌥↓")}>+</button>
            </div>
          </div>
          <div className="pop-foot">
            <button disabled={!L}>{tr("Other versions")}</button>
            <button disabled={!L} onClick={() => { onToast?.(tr("Reported")); setAnchor(null); }}>{tr("Wrong lyrics")}</button>
          </div>
        </Popover>
      )}
    </>
  );
}

function currentLyric(track, t) {
  const lines = track.lyrics?.lines;
  if (!lines) return null;
  const i = lyricLineIndex(lines, t);
  return i >= 0 ? lines[i] : null;
}

Object.assign(window, { NativeMenu, Popover, Switch, LyricsView, LyricsOptionsButton, KaraokeLine, lyricLineIndex, currentLyric, LYRIC_PROVIDERS });
