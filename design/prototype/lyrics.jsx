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

// ── Lyric translation: a separate setting from the interface language ───────────────
// pref: "auto" (follow interface language) | "off" | a language code below.
// Source: the provider's own translation when it matches the target (NetEase ships zh-Hans),
// otherwise on-device machine translation (Apple Translation framework in the app; Chrome's
// built-in Translator API in this prototype). Songs already in the target language get none.
const TRANSLATION_LANGS = [
  ["zh-Hans", "简体中文"], ["zh-Hant", "繁體中文"], ["en", "English"], ["ko", "한국어"], ["ja", "日本語"],
  ["vi", "Tiếng Việt"], ["es", "Español"], ["fr", "Français"], ["de", "Deutsch"],
];
const langName = (code) => TRANSLATION_LANGS.find(([c]) => c === code)?.[1] || code;

function resolveTranslationTarget(pref) {
  if (!pref || pref === "off") return null;
  if (pref === "auto") return window.QT_LANG === "zh-CN" ? "zh-Hans" : "en";
  return pref;
}

function detectLyricLang(lines) {
  const s = lines.slice(0, 12).map((l) => l.text).join(" ");
  if (/[぀-ヿ]/.test(s)) return "ja";
  if (/[가-힯]/.test(s)) return "ko";
  if (/[一-鿿]/.test(s)) return "zh-Hans";
  if (/[ăâđêôơưạảấầẩẫậắằẳẵặẹẻẽếềểễệỉịọỏốồổỗộớờởỡợụủứừửữựỳỵỷỹ]/i.test(s)) return "vi";
  return "en";
}
const sameLang = (a, b) => a === b || (a.startsWith("zh") && b.startsWith("zh"));
const chromeCode = (c) => (c === "zh-Hans" ? "zh" : c);

const trCache = new Map();      // `${trackId}|${target}` -> { status, lines }
const trListeners = new Set();
const trNotify = () => trListeners.forEach((l) => l());

// Language models must be downloaded with the user's consent (a click) — same as Apple's Translation framework.
async function machineTranslate(lines, from, to, { allowDownload = false } = {}) {
  if (!("Translator" in self)) throw new Error("unavailable");
  const opts = { sourceLanguage: chromeCode(from), targetLanguage: chromeCode(to) };
  const av = await Translator.availability(opts);
  if (av === "unavailable") throw new Error("unavailable");
  if (av !== "available" && !allowDownload) throw new Error("download");
  const translator = await Translator.create(opts);
  const memo = new Map();
  const out = [];
  for (const l of lines) {
    if (!memo.has(l.text)) memo.set(l.text, await translator.translate(l.text));
    out.push(memo.get(l.text));
  }
  return out;
}

function useLyricTranslation(track, pref) {
  const [, force] = useState(0);
  useEffect(() => { const l = () => force((n) => n + 1); trListeners.add(l); return () => trListeners.delete(l); }, []);
  const target = resolveTranslationTarget(pref);
  const L = track.lyrics;
  const songLang = L ? detectLyricLang(L.lines) : null;
  const key = `${track.id}|${target}`;
  const needsDevice = !!(L && target && !sameLang(songLang, target) && !(target === "zh-Hans" && L.lines.some((l) => l.tr)));
  useEffect(() => {
    if (!needsDevice || trCache.has(key)) return;
    const entry = { status: "pending", lines: null };
    trCache.set(key, entry);
    trNotify();
    machineTranslate(L.lines, songLang, target)
      .then((lines) => { entry.status = "ready"; entry.lines = lines; })
      .catch((e) => { entry.status = e.message === "download" ? "download" : "unavailable"; })
      .finally(trNotify);
  }, [key, needsDevice]);
  const download = () => {   // must run inside the click handler
    const entry = trCache.get(key);
    entry.status = "pending"; trNotify();
    machineTranslate(L.lines, songLang, target, { allowDownload: true })
      .then((lines) => { entry.status = "ready"; entry.lines = lines; })
      .catch(() => { entry.status = "unavailable"; })
      .finally(trNotify);
  };
  if (!L || !target) return { target, status: "off", lines: null, source: null };
  if (sameLang(songLang, target)) return { target, status: "same", lines: null, source: null };
  if (!needsDevice) return { target, status: "ready", lines: L.lines.map((l) => l.tr || null), source: L.source.replace(/ \(.*\)/, "") };
  const e = trCache.get(key) || { status: "pending", lines: null };
  return { target, status: e.status, lines: e.lines, source: "device", download };
}

// Current line + its translation, for single-line surfaces (video overlay, desktop lyrics, menu bar).
function useCurrentLyric(track, pref, fps = 10) {
  const pos = usePosition(fps);
  const T = useLyricTranslation(track, pref);
  const lines = track.lyrics?.lines;
  if (!lines) return { ln: null, tr: null };
  const i = lyricLineIndex(lines, pos + player.state.lyricOffset);
  return { ln: i >= 0 ? lines[i] : null, tr: i >= 0 ? T.lines?.[i] || null : null };
}

function LyricsView({ track, mode = "panel", align = "left", translation = "auto", anchor = 0.36 }) {
  const p = usePlayer();
  const T = useLyricTranslation(track, translation);
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
  }, [idx, track.id, translation, T.status, mode, lines]);

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
              {T.lines?.[i] && <div className="ly-tr">{T.lines[i]}</div>}
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
  const T = useLyricTranslation(track, translation);
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
          <div className="pop-row">
            <span>{tr("Translate to")}</span>
            <select className="pop-select" value={translation} onChange={(e) => setTranslation(e.target.value)} aria-label={tr("Translate to")}>
              <option value="auto">{tr("Interface language")} · {langName(resolveTranslationTarget("auto"))}</option>
              <option value="off">{tr("Off")}</option>
              <option disabled>──────────</option>
              {TRANSLATION_LANGS.map(([c, n]) => <option key={c} value={c}>{n}</option>)}
            </select>
          </div>
          {T.status !== "off" && (
            <div className="pop-note">
              {T.status === "same" ? tr("Song is already in {x}", { x: langName(T.target) })
                : T.status === "pending" ? tr("Translating…")
                : T.status === "download" ? <button className="pop-link" onClick={T.download}>{tr("Download {x} for offline translation", { x: langName(T.target) })}</button>
                : T.status === "unavailable" ? tr("Translation unavailable on this device")
                : T.source === "device" ? tr("On-device translation") : tr("Translation by {x}", { x: tr(T.source) })}
            </div>
          )}
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

Object.assign(window, { TRANSLATION_LANGS, langName, resolveTranslationTarget, useLyricTranslation, useCurrentLyric, NativeMenu, Popover, Switch, LyricsView, LyricsOptionsButton, KaraokeLine, lyricLineIndex, currentLyric, LYRIC_PROVIDERS });
