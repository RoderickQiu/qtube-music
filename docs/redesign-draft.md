# QTube Music — Redesign Draft v0.2

*Status: approved direction v0.2 · 2026-10-18*

**Thesis.** A Mac-native YouTube Music player built around the now-playing experience.
NetEase Cloud Music's player soul, YouTube Music's catalog and music videos, Apple-grade Mac manners —
and none of the rest of YouTube.

---

## 1. Why another client

| Source | What's wrong today |
|---|---|
| YouTube Music (web / PWA) | No Mac app. Web interactions, lazy-loaded library you can't sort or jump through, queue nobody can find. |
| Kaset (native Swift, MIT) | Plays audio through a hidden 1×1 WebView driven by ~6k lines of injected JS → tracks that stop advancing (#280, #409), fragile gapless, duplicate Now Playing (#457). No now-playing screen (#481; PRs #267/#289/#440 unmerged for months). MV button disabled for most tracks; no Song⇄Video switch. ~18% of the code is general YouTube (Shorts, comments, Gemini). Single-click plays instead of selecting (#446), no ⌘F in playlists (#431), no shuffle-library (#546). |
| NetEase Cloud Music (reference) | Gets the player right — but upsells mid-playback, animated skins cost ~62% CPU / 570 MB because they render in Chromium, and fancy typography breaks non-Chinese scripts. |
| YTubic 0.5.1 (Tauri/React, GPL-3.0) | Best-looking third-party client (docked now-playing panel, art-tinted window, line-synced lyrics from LRCLIB/Musixmatch/Genius, crossfade, 9-band EQ). But: playback spawns a yt-dlp process per track (breaks when YouTube changes; no gapless), **Premium-only by policy**, no word-sync, no translation, Song/Video only swaps audio (no video at all), Radix web menus, only Space as a shortcut, Tauri default menu bar. macOS is a contributor-maintained beta, ad-hoc signed, not notarized. 176/183 commits by one author with Claude; no maintainer replies since 2026-09-23. |
| JustAnotherMusicClient 1.3.2 (Tauri/React, Apache-2.0) | Fast search, per-tab queues, decent LRCLIB line-synced lyrics view. But: audio plays through a **hidden YouTube iframe** (embed-disabled tracks fail with errors 150/5; no gapless/EQ; no video), measured **~100% CPU and ~800 MB while paused** on this Mac, traffic lights on the right in Windows order, ⌘Space search collides with Spotlight, Ctrl-S not ⌘S, Now Playing has no artwork, the mini player pops onto your screen and steals focus at launch, no full-screen player (placeholder component). Not notarized; no commits since 2026-08-18. |

**What the community is asking for** (r/YoutubeMusic, Dribbble, Behance, Oct 2026): a real desktop app
(395-pt thread; "multi-trillion-dollar company refuses to make a desktop app" +150), synced lyrics,
blurred-art backgrounds over gradients, clear shuffle/repeat states, a light theme, a queue that makes
sense, a library you can sort, A–Z jump and search, music videos that are one tap away, Discord + Last.fm.
The clients people rallied behind in 2026 — **YTubic** (1,483 pts), **JustAnotherMusicClient** (819),
**Kodama** (511) — are all web-stack apps (Tauri/Electron + React) built Windows-first by one person each.
Nobody owns *native Mac* yet.

**Why not just use YTubic or JAMC?** (hands-on test + code review, 2026-10-18) Both are fine YouTube Music
windows, but every headline feature here is missing in both — Stage player, word-synced lyrics, translation,
real music videos with Song⇄Video, native menus/shortcuts, gapless — and the gaps are architectural
(playback via yt-dlp subprocesses or a hidden iframe), not polish. Both maintainers have gone quiet.
What we'd do better, concretely: own the audio pipeline (preloaded `AVQueuePlayer` → gapless, EQ, no
helper processes), use InnerTube's song↔video counterpart for a same-timestamp MV switch, keep word timing
end-to-end, render with Core Animation/Metal instead of CSS blur and per-frame React updates, and ship
signed + notarized with Sparkle updates.

---

## 2. Principles

1. **Music only.** Songs, albums, artists, playlists, music videos. No Shorts, vlogs, comments, podcasts, or AI features.
2. **The player is the product.** Now Playing is a place you live in, not a modal you dismiss.
3. **Mac manners, everywhere.** Native menus, keyboard-first, selection semantics, drag & drop, menu bar, media keys. If Finder or Music.app does it a certain way, so do we.
4. **The library is a database, not a feed.** Sortable, searchable, jumpable, and it remembers where you were.
5. **Calm by default, expressive on demand.** Motion and visualizers are opt-in, GPU-native (Metal / Core Animation), and step down on battery / Low Power Mode.
6. **We own playback.** One source of truth for queue, Now Playing, and media keys — never shared with a web page.

---

## 3. Window anatomy

Three columns, one player that changes size.

```
┌───────────┬───────────────────────────────────────┬──────────────────────┐
│ ● ● ●     │  ‹ ›   ⌘K Search music…               │  ┌────────────────┐  │
│           │                                       │  │                │  │
│ Home      │   Artist / Album / Playlist / Home    │  │    ARTWORK     │  │
│ Explore   │   content                             │  │   (or video)   │  │
│ ───────── │                                       │  └────────────────┘  │
│ LIBRARY   │   # Title            Album     ♥  3:27│  [ Song | Video ]    │
│ Songs     │   1 Trú Mưa          HKT Vol.5 ♥  5:02│  Trú Mưa             │
│ Albums    │   2 Đơn Côi          Ru Nửa…   ♥  3:13│  HKT · HKT Vol.5     │
│ Artists   │   …                                   │  ━━━━━━●──────  1:02 │
│ Liked     │                                       │   ⤨  ⏮  ⏯  ⏭  ↻      │
│ History   │                                       │ ─────────────────────│
│ ───────── │                                       │ Lyrics│Up Next│Related│
│ PLAYLISTS │                                       │  Gió cứ rít réo rắt…  │
│ Sugar     │                                       │  午夜的风你尽管呼啸     │
│ 2025 Sel  │                                       │  ▸ Bao đêm qua em…    │
├───────────┴───────────────────────────────────────┴──────────────────────┤
│ ▣ Trú Mưa — HKT   ♥    ⤨ ⏮ ⏯ ⏭ ↻   ━━━━━●───────   🔊 ─●─   ▤  ⛶  ⧉       │
└──────────────────────────────────────────────────────────────────────────┘
```

- **Sidebar**: Home, Explore (New releases, Charts, Moods & genres), Library, pinned playlists. Drag songs onto a playlist to add them.
- **Content**: standard back/forward navigation that **keeps scroll position**. Prefetch on hover so clicks feel local (YTubic's "instant UI").
- **Now Playing panel** (docked inspector, the YTubic / Behance pattern): two tabs only, **Now Playing** (compact artwork header with Song|Video, then scrollable lyrics with a “Current” jump-back) and **Queue**. No transport controls (the player bar owns playback). Hidden from its own header button or the toolbar toggle (⌥⌘N), never only from the bottom bar.
- **Player bar**: always visible. Its buttons open lyrics / queue in the panel, the Stage (⛶) and the mini player (⧉).
- **Pinned headers**: playlist headers collapse into a compact sticky bar (title, Play, Shuffle, filter) with the column headings pinned beneath.
- **Home**: greeting + mood chips, Listen again, Quick picks (3-column), a **Music videos** shelf, your playlists. Built only from the user's own library and YouTube Music's real shelves.
- **Window tint**: the whole window takes a subtle tint sampled from the artwork, as NetEase and YTubic do. Blurred artwork sits behind the panel, which the community prefers to flat gradients.

---

## 4. One player, five sizes

| Size | Trigger | Purpose |
|---|---|---|
| Player bar | always | transport + progress |
| Docked panel | default on wide windows | art, lyrics, queue while browsing |
| **Stage** | click artwork / ⌘⇧F / green button | the immersive now-playing screen |
| Mini player | ⌘⇧M | floating, always-on-top, all Spaces |
| Menu bar + desktop lyrics | menu bar item / ⌘⇧L | control without any window |

### 4.1 Stage (the full-screen player)

This is the core of the app, and the one thing Kaset and YouTube Music don't have.

```
┌──────────────────────────────────────────────────────────────────────────┐
│ ⌄                                              Cover ▾   Song | Video   ⋯ │
│                                                                          │
│        ┌──────────────────────┐        Trú Mưa                           │
│        │                      │        HKT · HKT Vol.5 · 2019            │
│        │                      │                                          │
│        │       ARTWORK        │        Gió cứ rít réo rắt trong đêm       │
│        │   (cover / vinyl /   │        午夜的风你尽管呼啸                  │
│        │    music video)      │                                          │
│        │                      │     ▸  Bao đêm qua em vẫn nghẹn ngào      │
│        └──────────────────────┘        多少个夜晚我还是这样哽咽            │
│                                                                          │
│                                        Nếu anh đã thấu hiểu cho em       │
│                                                                          │
│  ━━━━━━━━━━━━━━━━━━━●──────────────────────────────────────────  1:02 5:02│
│                ⤨      ⏮      ⏯      ⏭      ↻          ♥   ▤   🔊         │
└──────────────────────────────────────────────────────────────────────────┘
```

- **Layout**: artwork left, lyrics right. This is NetEase's "Standard" layout, the one you picked. Two variants:
  - **Lyrics only**: lyrics centred, artwork becomes the background.
  - **Art only**: for instrumentals and tracks without lyrics. The app switches to it automatically when a track has no lyrics.
- **Chrome fades out** after 3 s of no mouse movement while playing (as NetEase does). Moving the mouse brings it back.
- **Quiet controls**: the top bar is icons only — Lyrics options, Appearance (layout glyphs + background swatches in one popover) — plus the Song | Video switch. A **Queue** drawer slides in from the right without leaving the Stage.
- **No explanatory copy on screen**: no placeholder labels, no “your song starts after this” style sentences; states speak through design.
- **Backgrounds** (Cover ▾ menu), a short curated set instead of 40 skins:
  1. **Blurred art** (default)
  2. **Full-bleed cover**
  3. **Vinyl**: the record spins and the tonearm lifts on pause
  4. **Video**: the music video plays in the art slot
  5. **Visualizer**: audio-reactive, drawn in Metal; off on battery by default (Premium engine only)
- **More variety later.** After v1, add more backgrounds and themes, but only ones that meet the same design bar: one coherent visual idea each, artwork-driven colour, legible lyrics in every script, Metal-rendered within the CPU budget, and no paywalled skins.
- **Multi-display**: the Stage can be sent to a second display ("Show Stage on U270CA") while the main window keeps browsing on the laptop screen.
- Supports true macOS fullscreen, and ⎋ returns to the window.

### 4.2 Mini player

- **Two modes**: compact (a 320×64 strip) and art (a 300×300 square with controls on hover). It floats above other windows, stays on all Spaces, and can be resized by dragging its edge.
- **Lyric line**: an optional single line of the current lyric at the bottom.

### 4.3 Menu bar and desktop lyrics

- **Menu bar**: a menu bar item shows the track title, with optional scrolling. Clicking it opens a popover with art, controls and a like button.
- **Desktop lyrics** (taken from NetEase): one or two lines in a click-through floating overlay. Font, size and position are adjustable, and it hides automatically when the Stage is visible.

---

## 5. Song ⇄ Video

This is YouTube Music's best idea, and Kaset doesn't have it.

- **Song | Video pill** in the docked panel and on the Stage, shown whenever a track has a linked version: an official MV for an audio track, or the audio track for a video.
- **Switching keeps your place**: playback jumps to the linked version at the same timestamp, with a short crossfade. The queue doesn't change.
- **Where the video plays**: in the docked panel the video replaces the artwork. On the Stage, Video becomes the background, with an optional synced-lyric overlay (inspired by the Dribbble "Music video + lyrics player" concept).
- **Native Picture-in-Picture** (⌘⇧P), so the video can float on its own.
- **No YouTube clutter** in video mode: no comments, no recommended-video grid, no "subscribe" prompts. The artist page gets a **Videos** row next to Songs and Albums (the Mahdi GZH concept, the most-liked shot on Dribbble).
- **Preference**: "Prefer videos when available", off by default.

---

## 6. Lyrics

- **Sources: a selectable provider chain** (tested live 2026-10-18 on EN/ZH/3×VI/JA/HI songs):

  | Tier | Providers | Default | What they add |
  |---|---|---|---|
  | Safe | YouTube Music (by videoId), **LRCLIB**, **AMLL TTML DB** (CC0, word-synced, mostly CJK) | on | Synced lyrics for 6 of 7 test songs; mostly line-level |
  | Community / unofficial | **NetEase** (Chinese translation lines + some word timing; found 7/7 incl. all Vietnamese), **Kugou** (word-synced 6/7, incl. all 3 Vietnamese), **QQ Music** (word-synced; search geo-filtered outside China) | off, one toggle each, labelled "may break / against the service's terms" | NetEase-level quality: karaoke timing + translations |
  | Not shipped | Better Lyrics API (keyed to their extension, resells Apple TTML), unofficial Musixmatch (now serves decoys and captchas), Apple Music / Spotify tokens | n/a | n/a |
  | Licensed option | Official Musixmatch API | later, if it's worth paying for | Licensed word sync + translations |

- **Engine:** build on **LyricsKit** (MxIris fork, MPL-2.0, Swift). It already parses NetEase, QQ, Kugou and LRCLIB lyrics and scores candidates.
- **Matching:**
  - clean "(Official Video)" noise out of titles;
  - fold Vietnamese diacritics and Traditional↔Simplified Chinese when comparing, but send the original spelling to providers;
  - score 0.4 title + 0.4 artist + 0.2 duration, rejecting results more than 20 s off;
  - learn artist and title aliases (周杰伦 = Jay Chou, Hạ Phỏm = 出牌).
- **Picking a result:**
  - word-synced beats line-synced beats plain;
  - never mix lines from two sources;
  - the translation lane may come from a second source, but only once its timestamps line up;
  - a "Wrong lyrics? / Other versions (n)" menu pins the choice per track;
  - results are cached in SQLite by videoId.
- **Gaps covered on device:** romanization through ICU (pinyin, Devanagari); English translation of Vietnamese through Apple's Translation framework, labelled "machine translation", since no provider supplies it.
- **Word-level highlight** when the timing data has it, otherwise line-level. The current line is large and full-opacity, the rest is dimmed and smaller. Lines spring-scroll into place.
- **Translation line** under each lyric, in a language you choose, with romanization for Japanese, Korean, Chinese, Thai and others.
- **Interaction**: click a line to seek. ⌥↑ and ⌥↓ nudge the lyric timing by ±0.1 s, saved per track (NetEase has this too).
- **Fonts per script**: each script gets a font chosen for it. This avoids NetEase's mixed-font Vietnamese bug.
- **Copying**: lyrics are selectable text, so ⌘C works.

---

## 7. Library and queue

### Library

- **Songs, Albums and Artists are real tables**:
  - sortable columns (title, artist, album, added, plays, duration); "The" is ignored when sorting
  - an **A–Z jump strip**
  - **⌘F filter** inside any list or playlist
  - multi-select with ⇧ and ⌘
- **Selection works like Finder**: single-click selects, double-click or ↩ plays (fixes Kaset #446).
- **Shuffle works everywhere**: **Shuffle** on every playlist, album and artist, plus **Shuffle entire library** (fixes Kaset #480 and #546).
- **Remembers position**: going back returns you to the same scroll position.

### Queue

The community says it can't find or understand the queue in YouTube Music. Ours has three labelled sections:
```
Now Playing   Trú Mưa — HKT
Up Next (you added)        ← Play Next / Add to Queue land here; drag to reorder
Autoplay · from "Liked"    ← radio continuation, visually distinct, can be turned off
```
- **Save and restore**: "Save queue as playlist" is one click. The queue survives quitting and relaunching.
- **Clear Up Next** has an undo.

---

## 8. Mac manners checklist

| Area | Behaviour |
|---|---|
| Menus | Real `NSMenu` context menus with shortcuts shown, and a full menu bar (Controls, View, Window) |
| Keys | Space play/pause · ⌘←/→ prev/next · ⌘L like · ⌘K search/command palette · ⌘⇧F Stage · ⌘⇧M mini · ⌘⇧V Song⇄Video · ⌘⇧L desktop lyrics · ⌘F filter · ⌘1–4 sidebar sections |
| Now Playing | Full ownership of `MPNowPlayingInfoCenter` and remote commands; media keys and AirPods controls work |
| System | Dock menu, menu bar item, Shortcuts / App Intents, AppleScript, notifications on track change (optional), Handoff-free |
| Windows | Remembers its frame per display; closing the window keeps music playing, with a setting to quit instead (asked for in the YTubic thread) |
| Drag & drop | Songs → sidebar playlists, songs → queue, reorder playlists |
| Appearance | Light / dark / auto (light mode is a frequent request). **Minimum macOS 15**: native materials (`NSVisualEffectView` / SwiftUI materials) everywhere, upgraded to Liquid Glass on macOS 26+ via `#available` |
| Accessibility | VoiceOver labels on every control, Reduce Motion turns off the Stage animations, Dynamic Type for lyrics |

---

## 9. Visual language

- **Colour**: neutral system surfaces, with one **accent sampled from the current artwork**. It tints the progress bar (which a Reddit commenter specifically asked for), the selected row and the panel background.
- **Typography**: SF Pro, with per-script fallbacks. Lyrics use a larger optical size. Numbers use tabular figures.
- **Clear states**: shuffle and repeat use a filled background when on, not a subtle colour shift. This is a common complaint about YouTube Music.
- **Motion**: springs for lyric scroll, the vinyl tonearm and the panel slide; nothing on a loop unless you picked an animated background.
- **Performance targets**: idle under 1% CPU. Under 8% CPU while playing on the Blurred art background. Visualizer under 15%, rendered in Metal.

---

## 10. Integrations (in priority order)

1. Last.fm scrobbling
2. Discord Rich Presence, the most-requested feature in every client thread
3. AirPlay 2
4. Local files and uploads alongside YouTube Music (requested in the YTubic thread)
5. Later: control from your phone

---

## 11. Engine and policy

This is not a visual decision, but it shapes the design.

- **Playback: two engines behind one `PlaybackEngine` protocol** (decided: free accounts can play, not Premium-only).
  - **Premium accounts → native engine.** Resolve the audio stream and play it through a preloading `AVQueuePlayer` / `AVAudioEngine`. This gives true gapless playback, crossfade, EQ and visualizer data. It means handling YouTube's stream protection, which is the core ongoing engineering cost.
  - **Free accounts → web engine.** A minimal headless WebView where YouTube's own player plays the track, **including its ads**. This keeps free playback within YouTube's terms. The bridge is kept tiny (Kaset's 6k-line bridge is the anti-pattern), and the queue, Now Playing and media keys are still owned natively.
  - **What free users get:** gapless, crossfade, EQ and the visualizer are Premium-engine features. Free users see them greyed out with a one-line explanation, never an upsell popup.
  - **Ad state:** while an ad plays, the player shows a calm **"Ad · 0:15"** state. Artwork dims, lyrics pause, the scrubber is disabled, and skip appears when YouTube allows it. No fake controls.
- **Data and sign-in**: YouTube Music's internal API (as Kaset uses), with sign-in through an embedded Google login page, music endpoints only. Kaset's data-layer patterns are MIT-licensed and can be reused with attribution.

---

## 12. Out of scope for v1

General YouTube (Shorts, subscriptions feed, comments), podcasts (decided: skipped entirely), AI features, social features, a 40-skin store, a Windows or Linux version.

## 13. Milestones

| | Deliverable |
|---|---|
| M0 | Claude Design mockups of: window + docked panel, Stage (3 backgrounds), mini player, Song⇄Video |
| M1 | SwiftUI shell with mock data; Stage + lyrics renderer with word sync |
| M2 | Sign-in + data layer (home, library, playlists, search) |
| M3 | Playback engine + Now Playing + queue model |
| M4 | Song⇄Video + PiP |
| M5 | Library tables, mini player, menu bar, desktop lyrics, Last.fm / Discord |

## 14. Decisions (2026-10-18)

1. **Name:** QTube Music.
2. **Playback:** free accounts can play, not Premium-only. Two engines (see §11).
3. **Podcasts:** skipped entirely and filtered out of home, search and library.
4. **Backgrounds:** five curated for v1; more variety later, held to the design bar in §4.1.
5. **Minimum macOS:** 15, with Liquid Glass on 26+.
6. **Unofficial lyrics sources** (NetEase, Kugou, QQ): off by default, one opt-in toggle each.

---

## Appendix: evidence

- **NetEase Cloud Music 3.1.13**, explored live through Chromium DevTools:
  - native shell (Obj-C) wrapped around a React app in CEF
  - native audio engine, `NSMenu` context menus, SQLite cache, desktop lyrics, menu bar control and Touch Bar
  - 3 player layouts × ~40 skins
  - Standard layout = turntable + translated synced lyrics + art-tinted background + auto-hiding controls
- **Kaset** codebase review (`/tmp/kaset`, HEAD 2026-10-18): WebView playback (ADR-0001), no music fullscreen, Song⇄Video not implemented, 28 open PRs (~18 older than 6 weeks).
- **Reddit r/YoutubeMusic**:
  - YTubic (1,483 / 685 pts), JustAnotherMusicClient (819), Kodama (511)
  - the radinwaves concept (1,001), LinzerKyle redesign v2 (229)
  - the desktop concept series v1–v3 (425 / 233)
  - library complaints ("129 songs before the letter A", 125)
  - the team's own "Acknowledging your feedback" post (210)
- **Dribbble**: about 380 shots across 8 searches; most relevant: Mahdi GZH (artist page with Videos), the Music video + lyrics player, Musixmatch word-highlight lyrics, translation pickers, and the Robert Licau macOS music kit.
- **Behance**: "YouTube Music Desktop App" (three-column layout with a docked Up Next / Lyrics / Related panel) and a Korean redesign case study.
- **GitHub**: better-lyrics/better-lyrics (★937, GPL-3.0, word-synced TTML), NUber-dev/YTubic (★323, GPL-3.0), 2latemc/JustAnotherMusicClient (★292, Apache-2.0); all TypeScript.
