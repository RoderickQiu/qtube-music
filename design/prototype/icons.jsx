// Line icons in the spirit of SF Symbols (1.7 stroke, round caps). Placeholders for the real symbols.
const iconPaths = {
  play: <path d="M7 4.5v15l12-7.5z" fill="currentColor" stroke="none" />,
  pause: <g fill="currentColor" stroke="none"><rect x="6" y="4.5" width="4" height="15" rx="1" /><rect x="14" y="4.5" width="4" height="15" rx="1" /></g>,
  next: <g fill="currentColor" stroke="none"><path d="M4 5v14l10-7z" /><path d="M13 5v14l8-7z" /></g>,
  prev: <g fill="currentColor" stroke="none"><path d="M20 5v14L10 12z" /><path d="M11 5v14l-8-7z" /></g>,
  shuffle: <g><path d="M3 7h3.5c2 0 3.2 1 4.3 2.7l2.4 4.6c1 1.7 2.3 2.7 4.3 2.7H21" /><path d="M3 17h3.5c1.4 0 2.4-.5 3.3-1.4" /><path d="M14.4 8.4c.8-.9 1.8-1.4 3.1-1.4H21" /><path d="M18.5 4.5 21 7l-2.5 2.5M18.5 14.5 21 17l-2.5 2.5" /></g>,
  repeat: <g><path d="M4 11V9a3 3 0 0 1 3-3h13" /><path d="M17 3l3 3-3 3" /><path d="M20 13v2a3 3 0 0 1-3 3H4" /><path d="M7 21l-3-3 3-3" /></g>,
  heart: <path d="M12 20s-7.5-4.4-7.5-10A4.3 4.3 0 0 1 12 7.3 4.3 4.3 0 0 1 19.5 10C19.5 15.6 12 20 12 20z" />,
  heartFill: <path d="M12 20s-7.5-4.4-7.5-10A4.3 4.3 0 0 1 12 7.3 4.3 4.3 0 0 1 19.5 10C19.5 15.6 12 20 12 20z" fill="currentColor" />,
  home: <g><path d="M4 11 12 4l8 7" /><path d="M6 10v9h12v-9" /></g>,
  compass: <g><circle cx="12" cy="12" r="8.5" /><path d="m15.5 8.5-2 5-5 2 2-5z" /></g>,
  note: <g><path d="M9 18V6l10-2v12" /><circle cx="6.5" cy="18" r="2.5" /><circle cx="16.5" cy="16" r="2.5" /></g>,
  album: <g><rect x="3.5" y="3.5" width="17" height="17" rx="2" /><circle cx="12" cy="12" r="3.5" /></g>,
  mic: <g><rect x="9" y="3" width="6" height="11" rx="3" /><path d="M5.5 11a6.5 6.5 0 0 0 13 0M12 17.5V21" /></g>,
  clock: <g><circle cx="12" cy="12" r="8.5" /><path d="M12 7.5V12l3 2" /></g>,
  list: <g><path d="M8 6h12M8 12h12M8 18h12" /><circle cx="4" cy="6" r=".6" fill="currentColor" /><circle cx="4" cy="12" r=".6" fill="currentColor" /><circle cx="4" cy="18" r=".6" fill="currentColor" /></g>,
  playlist: <g><path d="M4 6h11M4 11h11M4 16h7" /><path d="M18 9v8" /><circle cx="16.5" cy="17.5" r="1.8" /></g>,
  search: <g><circle cx="11" cy="11" r="6.5" /><path d="m16 16 4 4" /></g>,
  chevL: <path d="m14 6-6 6 6 6" />,
  chevR: <path d="m10 6 6 6-6 6" />,
  chevD: <path d="m6 9 6 6 6-6" />,
  chevU: <path d="m6 15 6-6 6 6" />,
  expand: <g><path d="M14 4h6v6M10 20H4v-6M20 4l-7 7M4 20l7-7" /></g>,
  mini: <g><rect x="3" y="5" width="18" height="14" rx="2" /><rect x="12" y="12" width="7" height="5" rx="1" fill="currentColor" stroke="none" /></g>,
  lyrics: <g><path d="M4 5h16v11H9l-5 4z" /><path d="M8 9h8M8 12h5" /></g>,
  volume: <g><path d="M4 9.5h3.5L12 6v12l-4.5-3.5H4z" /><path d="M15.5 9.2a4 4 0 0 1 0 5.6M18 7a7.2 7.2 0 0 1 0 10" /></g>,
  airplay: <g><path d="M6 17H4.5A1.5 1.5 0 0 1 3 15.5v-9A1.5 1.5 0 0 1 4.5 5h15A1.5 1.5 0 0 1 21 6.5v9a1.5 1.5 0 0 1-1.5 1.5H18" /><path d="m12 14 5 6H7z" /></g>,
  more: <g fill="currentColor" stroke="none"><circle cx="6" cy="12" r="1.6" /><circle cx="12" cy="12" r="1.6" /><circle cx="18" cy="12" r="1.6" /></g>,
  sidebar: <g><rect x="3" y="4.5" width="18" height="15" rx="2" /><path d="M15 4.5v15" /></g>,
  grip: <g><path d="M8 7h8M8 12h8M8 17h8" /></g>,
  video: <g><rect x="3" y="6" width="13" height="12" rx="2" /><path d="m16 10.5 5-3v9l-5-3z" /></g>,
  check: <path d="m5 12.5 4.5 4.5L19 7.5" />,
  layers: <g><path d="m12 4 9 5-9 5-9-5z" /><path d="m3 14 9 5 9-5" /></g>,
  close: <path d="M6 6l12 12M18 6 6 18" />,
  sparkle: <path d="M12 3.5 13.8 10 20.5 12l-6.7 2L12 20.5 10.2 14 3.5 12l6.7-2z" />,
  pin: <g><path d="M9 4h6l-1 5 3 3H7l3-3z" /><path d="M12 15v5" /></g>,
};

const Icon = ({ name, size = 16, stroke = 1.7, style, className }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={stroke}
    strokeLinecap="round" strokeLinejoin="round" style={style} className={className} aria-hidden="true">
    {iconPaths[name]}
  </svg>
);

Object.assign(window, { Icon });
