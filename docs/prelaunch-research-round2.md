# Pre-launch research, round 2

*Run 2026-10-21, after everything in [round 1](prelaunch-implementation.md) was built. This round looked for what
round 1 missed:*
- *the newer competitors' issue trackers: Limusic (1.2k ★, 373 issues), Orchard (146), Kodama (18), and Kaset again;*
- *feature requests, not bugs, across Pear Desktop, ytmdesktop and ytmdesktop2;*
- *27 Reddit threads from the past year on r/YoutubeMusic and r/macapps, read with ego (about 1,000 comments);*
- *the yt-dlp tracker, for how YouTube exposes its AI label.*

*Each finding was then checked against the code on `main`.*

## What people want that QTube doesn't do yet

Ranked by how often and how strongly it comes up. Size: S = a day or less with agents, M = a few days, L = more.

| # | Item | Evidence | QTube today | Size |
|---|---|---|---|---|
| 1 | **Keep AI music out**: skip songs YouTube labels as AI-made, plus "Don't Play This Artist" | "probably the most requested feature here" (84↑); "I'm leaving YTM" (231↑, 189 comments); "AI songs make core features unusable" (147↑); YouTube added AI labels on 2026-10-16 with **no filter** ("I want a toggle to turn them off", 62↑); Pear #4639, Limusic #161 | Nothing | M |
| 2 | **Start Radio** from any song, album, artist or playlist | Orchard #173, Kodama #4, the Companion extension thread, and r/YoutubeMusic's "Can't find Go to Song Radio" | The client can fetch radio (`RDAMVM`) but no menu offers it | S |
| 3 | **Sleep timer** (fade out over N minutes, or stop at the end of the song) | Pear #2484 (8👍), Orchard #70, YouTempo's most-used addition, a new thread posted today | Nothing | S |
| 4 | **Equalizer and volume normalisation on the default engine** (crossfade too, if possible) | "Crossfade" (40↑) and "Volume normalization" (24↑) in "Features that urgently need adding"; "Still no Crossfade?" (48 comments); Pear #3032 (13👍); the YouTempo and crossfade extensions | Crossfade, EQ and gapless exist **only on the opt-in native Premium engine**, so free users and the default web engine get none | M (EQ, normalisation) / L (crossfade on the web engine) |
| 5 | **Add a song to several playlists at once** | Top comment in "Features that urgently need adding" (51↑); its own thread; round-1 Reddit (a user with 200+ playlists) | The Add to Playlist submenu closes after one pick | S |
| 6 | **Sidebar playlists: sort (A–Z, recently added, recently played) and folders** | "Alphabetically sort playlists. That's THEE most basic feature" (5↑); folders are a reason given for going back to Spotify; Kaset #436 | Sidebar order is YouTube's; no folders (YouTube has none, so they would be local to this Mac) | M |
| 7 | **Quieter toasts**: an option to stop "Added to Liked Songs" etc. | Pear #2711 (8👍) | Every like and add shows a toast | S |

### How the top items would work

- **AI filter (item 1):**
  - **The label:** yt-dlp #16271 documents where YouTube puts it on the watch page (`…structuredDescriptionContentRenderer.items[].howThisWasMadeSectionViewModel` → "Altered or synthetic content"). YouTube Music's player page very probably carries the same field in its `next` response, but **one live check is needed** to confirm the path.
  - **Settings › Playback toggle "Skip AI-generated music":** autoplay, radio, mixes and shuffle skip labelled songs. A labelled song you pick yourself still plays, with a small badge.
  - **The gap:** labels are self-disclosed, and Reddit points out that the mass uploaders strip them.
  - **"Don't Play This Artist":** a menu item on songs and artists. It keeps a local list (this Mac, with an editor in Settings) and skips and hides that artist everywhere.
  - **Community list:** `xoundbyte/soul-over-ai` (CC BY 4.0, 1,375 artists, updated this week) is almost all names (4 have YouTube links). Name matching would hit real artists who share a name, so it could at most be an opt-in extra, with attribution.
- **Start Radio (item 2):** add "Start Radio" to the song, album, artist and playlist menus and to Controls, using the existing `RDAMVM` / `next` continuation path.
- **Sleep timer (item 3):**
  - Controls › Sleep Timer: 15 / 30 / 45 / 60 / 90 minutes, End of Song, Custom…
  - A countdown in the menu bar popover and the player bar.
  - A 30–60 s fade at the end, then pause, and the sleep assertion is let go.
- **EQ and normalisation on the web engine (item 4):**
  - The page already has a Web Audio tap (`docs/web-audio.md`). Biquad filter nodes on that graph give the same 10-band presets the native engine has.
  - Normalisation can use the `loudnessDb` YouTube already sends with each track.
  - Crossfade on the web engine would need a second page playing the next track and a volume ramp across both. The Song⇄Video standby page is the starting point, but it's the risky part.

## Already done (these are selling points, not gaps)

- **A queue that works the way Spotify's does**, the #1 queue complaint about YTM ("Fix. The. Queue.", "The play queue is an abomination"). Playing a song keeps your Up Next, "Add to Queue" plays before the rest of the playlist, and Autoplay has its own switch in the queue.
- **True shuffle** over the whole playlist, up to 50 pages (about 5,000 songs). It's a uniform shuffle, and the same song never plays twice in a row. That answers the "spreadsheet proving YTM's shuffle repeats" thread (831↑), and sndell's new Windows client leads with the same feature.
- **Search within a playlist** (the filter field) and sortable song tables.
- **Scrobbling uses the primary artist** (Limusic #231, Kodama #16).
- **Romanized lyrics.**
- **Share links without tracking codes** (Pear #2762).
- **Plus everything from round 1:**
  - likes and playlists syncing to the account
  - brand accounts
  - Last.fm and ListenBrainz
  - uploads
  - global shortcuts
  - the mini player
  - playback speed
  - fixes for wrong lyrics
  - light and dark modes

## Not worth doing (or not possible)

- **Lossless / Dolby Atmos:** YouTube Music doesn't offer them.
- **Jam / listening parties:** no YouTube API for it.
- **Chromecast:** no Google Cast SDK for macOS; AirPlay already works.
- **Comments on songs:** not a music feature.
- **Spotify playlist import:** YouTube Music has a built-in transfer now.
- **Offline downloads:** against YouTube's terms, and the cached audio would be Premium-only anyway.
- **Widgets:** WidgetKit needs an app extension, which the SwiftPM build and ad-hoc signing make hard. Revisit with a Developer ID.

## Competitor notes

- **Limusic** (Tauri + Rust + Svelte, Linux, Windows and now Mac) is the fastest-growing. Reddit praises it as "lightweight"; its WebView uses 220–400 MB. Its top issues: uploads that don't play, ListenBrainz, macOS song notifications, a primary-artist scrobble setting, romanized lyrics, sleep, an updater.
- **Orchard** (Electron) has added smart crossfade, lossless "integration", an immersive player and a mobile app. Its users ask for offline caching, a sleep timer and Start Mix.
- **New Windows clients keep appearing** ("Because the other 44 posted in the past 2 months were not enough?"). On Mac it's still Kaset, Pear, and now Limusic.
- **Browser extensions** (Companion, YouTempo, Better Lyrics) fill the same gaps from inside the browser: mini player, sleep timer, EQ, crossfade, lyrics. That shows which features people go looking for.
