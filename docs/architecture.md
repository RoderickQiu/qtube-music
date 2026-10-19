# QTube Music — architecture

The contract for everyone building on the scaffold. Spec: `docs/redesign-draft.md` (v0.2). Visual source of
truth: `design/prototype/` (layout, copy, states). Native macOS look and behaviour override pixel-matching the
prototype (see *Native UI rules*).

## Modules

SwiftPM package `QTubeMusic` (`Package.swift`, tools 6.2, Swift 6 language mode, macOS 15).

| Target | Depends on | Contents | Owner |
|---|---|---|---|
| `QTCore` | — | Models (`QTTrack`, `QTAlbum`, `QTArtist`, `QTPlaylist`, `QTShelf`/`QTHomeFeed`, `QTArtworkPalette`), `QTQueue`, `QTLyricsDocument`, `QTSettings` + `QTSettingsStore`, `QTMockCatalog` + `QTCatalogService`, `QTFormat`, `QTLoc` localization, **all String Catalogs** | shared (scaffold) |
| `QTInnerTube` | QTCore | `QTInnerTubeClient` (actor: ytcfg scrape, WEB_REMIX context, hl/gl, SAPISIDHASH, TTL+LRU cache, retries, session-loss detection; account writes gated by `setAllowsAccountWrites`), parsers → QTCore models (music-only filter), `QTCounterpartResolver` (Song⇄Video), `QTInnerTubeCatalog` (`QTCatalogService`), `QTInnerTubeConfiguration` | data-layer |
| `QTAuth` | QTInnerTube | `QTAuthController` (`restore()`, `beginSignIn(hl:over:)`, `signOut()`, DEBUG-only session import), `QTSessionStore` (actor, Keychain `com.roderickqiu.qtube`), `QTAuthSession`/`QTCookie` (auth-cookie allowlist), `QTWebCookieStore`, `QTAuthState` | data-layer |
| `QTPlayback` | QTCore, QTInnerTube | `QTPlaybackEngine` protocol, `QTSimulatedPlaybackEngine`, `QTQueueController` (queue + context, shuffle/repeat, autoplay continuation, persistence via `QTQueueStore`, holds a process activity while playing), `QTNowPlayingController` (sole owner of Now Playing + remote commands), `Web/QTWebPlaybackEngine` (hidden WKWebView, JS bridge, ads), `QTPlaybackEngineSelector`, `QTNativePlaybackEngine` stub (M5) | playback |
| `QTPlaybackLab` | QTPlayback | dev-only executable: drives the web engine live, muted and anonymous (`swift run --scratch-path .build/<you> QTPlaybackLab --scenario basic`) | playback |
| `QTLyrics` | QTCore | `QTLyricsResolver` (actor, `QTLyricsProviding`): parsers (LRC, YRC, QRC, KRC, TTML), QRC/KRC decryption, providers (YouTube Music, LRCLIB, AMLL; NetEase/Kugou/QQ opt-in), matcher, `QTLyricsCache` (SQLite), romanization, translation plan; `QTMockLyricsProvider` | lyrics |
| `QTUI` | all | SwiftUI/AppKit UI, app model, theme | per folder, below |
| `QTubeMusicApp` (product `QTubeMusic`) | QTUI | `@main` app: `Window` (main), `Settings`, `MenuBarExtra`, `QTCommands`, app delegate | desktop |

Spec names → types: PlaybackEngine = `QTPlaybackEngine`, QueueController = `QTQueueController`,
NowPlayingController = `QTNowPlayingController`, WebPlaybackEngine = `QTWebPlaybackEngine`.

**No third-party dependencies.** LyricsKit was dropped at integration: its QRC/KRC/YRC parsers and decrypters
are not public, so `QTLyrics` has its own (zlib and sqlite3 come from the system). Do not add any dependency
without asking the user (Sparkle comes later).

### What runs today (after integration)

The app runs on mock data (`QTMockCatalog`, `QTMockLyricsProvider`) and `QTSimulatedPlaybackEngine`;
`QTPlayerModel` is a façade over `QTQueueController` with `nowPlaying: nil` and no queue store, so mock and
screenshot runs never take the user's media keys or overwrite a saved queue. Built and tested but not yet wired
into the app (next milestone): `QTInnerTubeClient` / `QTInnerTubeCatalog`, `QTAuthController`,
`QTWebPlaybackEngine` + `QTPlaybackEngineSelector`, `QTNowPlayingController`, `QTQueueStore`,
`QTLyricsResolver`.

## QTUI folder ownership

| Folder | Builder | Holds |
|---|---|---|
| `Shell/`, `Sidebar/`, `Home/`, `Library/` | window | main window layout, router, sidebar, Home, playlist/library tables |
| `NowPlaying/`, `PlayerBar/`, `Queue/` | player | docked inspector, player bar, `QTScrubber`, `QTTransportControls`, `QTQueueList` |
| `Lyrics/` | lyrics-ui | `QTLyricsView`, `QTLyricsOptionsButton` / `QTLyricsOptionsPopover` |
| `Stage/` | stage | `QTStageView` (layouts × backgrounds, chrome, drawer) |
| `Desktop/`, `Commands/`, `Settings/`, `Sources/QTubeMusicApp`, `Assets/AppIcon.icns` | desktop | mini player, desktop lyrics, menu bar, `QTDesktopCoordinator`, menus, Settings, app icon |
| `Theme/`, `Shared/`, `AppModel/` | shared | builders may **add**; don't rename, repurpose or break existing API |

Edit only your folders and your String Catalog table. Need a change in someone else's area or in a shared
signature? Add a defaulted parameter or a new type in your own folder, and say so in your report.

## Shared APIs (frozen signatures)

State (environment, `@MainActor @Observable`):
- `QTAppModel` — `@Environment(QTAppModel.self)`. `surface` (`.window/.stage/.mini`), `sidebarSelection`
  (`QTSidebarItem`), `selectedTrackIDs`, `isPanelShown`, `panelTab` (`.nowPlaying/.queue`), `isVideoMode`,
  `account` (`.premium/.free`), `searchText`, `toast` + `showToast(_:undo:)`, persisted shortcuts `stageLayout`,
  `stageBackground`, `theme`, `lyricsTranslation`, `isDesktopLyricsShown`, `resolvedTranslationLanguage`, `palette`,
  `catalog` (`QTMockCatalog`), `settings` (`QTSettingsStore`), `launch` (`QTLaunchOptions`). One per process:
  `QTAppModel.shared`.
- `QTPlayerModel` — `@Environment(QTPlayerModel.self)`. UI façade over playback: `state`, `timeline`, `queue`,
  `nowPlaying`, `isPlaying`, `ad`, `duration`, `lyrics`, `mode` (song/video), `likedTrackIDs`, `isShuffleOn`,
  `repeatMode`; `play(_:startingAt:source:startTime:autoplay:mode:)`, `togglePlayPause`, `next`, `previous`,
  `seek`, `setVolume`, `setMode`, `skipAd`, `toggleLike`, `playNext`, `addToQueue`, `removeFromQueue`,
  `moveInQueue`, `clearUpNext`/`undoClearUpNext`, `jump(to:)`, `nudgeLyricsOffset(by:)`. The playback builder
  moves the internals into `QTQueueController`/`QTNowPlayingController` and keeps this API.

Views:
- `QTArtworkView(_ images:cornerRadius:contentMode:placeholder:)`, `QTArtworkView(track:video:cornerRadius:contentMode:)`
  — downsampled, cached (`QTImageLoader`), no borders, holds readiness while loading.
- `QTLyricsView(document:time:style:showsTranslation:onSeek:)` — `time` is a `QTPlaybackTimeline` (anchor + rate);
  the view interpolates itself, so parents re-render only on play/pause/seek. `style`: `.panel`, `.stage(centered:)`,
  `.mini`, `.desktop`. `onSeek` gets a playback time.
- `QTLyricsOptionsButton(overArt:)` → system popover with `QTLyricsOptionsPopover()`.
- `QTQueueList(style: .panel | .stageDrawer)`.
- `QTTransportControls(style: .playerBar | .stage | .compact)`; `QTScrubber(overArt:)`.
- `QTSongVideoToggle(isVideo:hasVideo:)` — segmented Picker.
- `QTToastOverlay()`, `QTIcon` (prototype icon name → SF Symbol; test checks every symbol exists).
- `QTNowPlayingIndicator.symbolName/image(isPlaying:)` + `QTNowPlayingGlyph(isPlaying:)` (Shared/) — the one marker for
  the current track in tables and lists: speaker only while playing, pause glyph while paused.
- `QTAdTint.color(overArt:increasedContrast:)` (PlayerBar/) — the amber ad colour (scrubber fill + "Ad" label).
- Window plumbing: `QTWindowID` (identifiers + capture titles), `QTWindowAccessor`, `QTWindowPlacement`,
  `QTReadiness` (`hold`/`release` around anything async the first frame needs).

Coordinators (one per process, `@MainActor`):
- `QTNavigator.shared` (Shell/) — content-column navigation: `go(.section(…) | .album(…) | .artist(…))`,
  `goBack`/`goForward` (history 64), per-page list state, `requestSearchFocus()` / `requestFilterFocus()`. Navigate
  through it so moves enter history; setting `model.sidebarSelection` still works.
- `QTStageCoordinator.shared` (Stage/) — `toggleStage(model:)` (⇧⌘F; closes a detached Stage), `showDetached(on:model:activate:)`,
  `returnToMainWindow(model:)`, `isDetached`.
- `QTDesktopCoordinator.shared` (Desktop/) — mini player, desktop lyrics (hidden while the Stage is up, inline or
  detached), menu bar title, Dock menu, `showMainWindow()` (user-initiated only).
- `QTLyricsTiming.nudge(model, by:)` (Lyrics/) — offset change + toast; `QTLyricsVersionStore.shared`.

Keyboard ownership: `QTCommands` (Commands/) is the only menu definition — every shortcut is bound once there
(navigation items call `QTNavigator`). Space in the main window is consumed by `QTWindowKeyMonitor` (Shell/);
elsewhere the Controls menu's Space fires. `QTKeyRouting` hands Space / ⌘←→ / ⌘↑↓ / ⌥↑↓ to a text field being
edited, and bare Space to a focused control. Esc is handled inside the Stage (`.cancelAction`), not in menus.

Core:
- `QTPlaybackEngine` (`@MainActor`): `capabilities`, `state`, `stateUpdates()` (new `AsyncStream` per subscriber,
  current state first), `load(_:autoplay:)`, `play`, `pause`, `seek(to:)`, `setVolume`, `setMuted`, `skipAd`,
  `stop`, `spectrum(bandCount:)`. `QTPlaybackState` carries `status` (idle/loading/playing/paused/ended/failed),
  `timeline`, `duration`, `isBuffering`, `ad: QTAdState?` (`remaining`, `skippableIn`, `canSkip`), `volume`.
  `QTSimulatedPlaybackEngine(account:)`: free → 12 s ad, skippable after 5 s; `playAd()`; `tick()` for tests.
- `QTQueue`: `nowPlaying` · `upNext` (user) · `autoplay` (+ `autoplaySource`, `isAutoplayEnabled`), `history`;
  `play(_:startingAt:source:)`, `playNext`, `addToQueue`, `insert`, `move` (SwiftUI `onMove` semantics, and
  between sections), `remove`, `clearUpNext() -> token` / `undoClearUpNext`, `advance`, `goBack`. Codable.
- `QTLyricsDocument`: lines → words (start/duration), `translation` / `romanization` lanes, `syncKind`, `source`,
  `language`, `confidence`, `offset` (**positive = lyrics earlier**; ⌥↑ "Lyrics Earlier" = +0.1),
  `lineIndex(atPlaybackTime:)`, `playbackTime(forLine:)`, `withOffset(nudgedBy:)`.
- `QTCatalogService` (home, liked, playlists, playlist, track). `QTMockCatalog` implements it for M1;
  InnerTube implements it in M3.
- `QTBrowseService` (Shell/, window): `explore() -> QTExploreContent` (new releases, top songs, videos, mood groups),
  `mood(_:) -> [QTShelf]`, `search(_:) -> QTSearchResults`, `album(_:) -> QTAlbumPage?`, `artist(_:) -> QTArtistPage?`
  — the `QTInnerTubeClient` page types. `QTBrowse.service` is `QTMockBrowseService` (derived from the mock catalog)
  until the data layer assigns an InnerTube-backed service; pages reload on interface-language change.
- Window controls: `QTPillButtonStyle(prominence: .primary | .secondary, iconOnly:)` (capsule; primary = artwork
  accent fill), `QTChipToggleStyle` (mood/genre chips), `QTChipFlow` (wrapping layout) — Shell/QTWindowButtonStyles.swift.
- Navigation: `QTDestination` adds `.mood(QTMoodChip)` (Explore mood/genre pages).

## Native UI rules (user requirement)

The prototype defines layout, hierarchy, copy and states; the app must look like a first-class Mac app.
- Native controls: `NavigationSplitView` sidebar (system material, source-list selection), real toolbar +
  `.searchable`, `.inspector` for the docked panel, `Table`/`NSTableView` with system headers, `Picker`
  (segmented/menu), `Toggle` (`.button` style for shuffle/repeat = filled when on), `Slider`, `Stepper`, `Menu`,
  `.popover`, grouped `Form` in Settings, `NSMenu`/`.contextMenu`, sheets/alerts.
- System semantics only: `QTTheme.Colors` wraps label/secondary/tertiary/separator/window/selection colours,
  materials (`.bar`, `.regularMaterial`, `.sidebar`), `qtFloatingSurface` = Liquid Glass on macOS 26 via
  `#available`, material before, solid with Reduce Transparency. Artwork accent is a **tint only**
  (`.qtArtworkTint(palette)` sets `.tint` + `\.qtAccent`; system accent under Increase Contrast).
- Type: system text styles via `QTTheme.Typography` (SF Pro; PingFang SC only via the system cascade — never name
  a CJK font first; no forced uppercase/tracking on CJK). Tabular figures with `.monospacedDigit()`.
- Motion: `QTTheme.Motion` (curve `cubic-bezier(.2,.8,.2,1)`, 320 ms UI, 520 ms lyric scroll, springs,
  `caTimingFunction`); always pass through `Motion.animation(_:reduceMotion:)`.
- Custom drawing only where AppKit has no equivalent: karaoke renderer, Stage backgrounds, artwork tiles.
- Taste rules: no explanatory/placeholder copy; quiet icon buttons + popovers; no boxes/borders behind lyrics or
  art; generous padding; transport only in the player bar (panel has none); panels close from their own header;
  lyrics scroll freely with a "Current" jump-back; sticky compact playlist header; full-bleed cover = frosted + grain.
- VoiceOver labels on every control (`Label` + `.labelStyle(.iconOnly)`), `.help` tooltips with shortcuts,
  specific accessibility identifiers (`qt.<area>.<control>`).

## Localization

- Call `QTLoc.tr("English key")` / `QTLoc.tr("Skip in %lld", 5)` / `QTLoc.tr("Key", table: .stage)`. Keys are the
  en-US strings; `%@` text, `%lld` integers; positional `%1$@` in translations. Never `Text("literal")` with a
  localizable string — use `Text(QTLoc.tr(…))`; use `Text(verbatim:)` for non-translatable text (language names).
- Runtime switching without restart: `QTLocalizer` resolves the chosen `.lproj` and is `Observable`; bodies that
  call `QTLoc.tr` re-render when `settings.interfaceLanguage` changes. System-provided menu items follow the
  launch language only.
- Catalogs live in `Sources/QTCore/Resources/Localization/` (one bundle for every module):

  | Table (`QTStringTable`) | File | Who adds keys |
  |---|---|---|
  | `.shared` | `Localizable.xcstrings` | all 160 prototype keys + scaffold keys; **don't add** new keys here |
  | `.main` | `Main.xcstrings` | window builder |
  | `.player` | `Player.xcstrings` | player builder |
  | `.lyrics` | `Lyrics.xcstrings` | lyrics-ui + lyrics builders |
  | `.stage` | `Stage.xcstrings` | stage builder |
  | `.desktop` | `Desktop.xcstrings` | desktop builder |

  A table lookup falls back to `.shared`, so existing keys work from any table. Add entries as JSON:
  `"Key" : { "localizations" : { "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "…" } } } }`.
  Plurals: copy the `"%lld songs · %lld min"` entry (en `substitutions` with `plural` variations). Don't set
  `"extractionState" : "manual"` (it turns on symbol generation, which fails on near-duplicate keys).
- Formatting: `QTFormat.duration/remaining/signedOffset/clock/songCountAndMinutes` (interface locale).
- Tests fail if a `QTLoc.tr("…")` literal or `.localized("…")` key lacks a zh-Hans translation in its table,
  if any catalog entry lacks zh-Hans, or if a prototype key is missing.

## Launch arguments

UserDefaults-style, session-only, never persisted: `open -g -n "QTube Music.app" --args -qt.surface stage …`.
Booleans: `YES/NO`, `true/false`, `1/0` (empty = true).

| Key | Values | Prototype |
|---|---|---|
| `qt.surface` | `window` · `stage` · `mini` (`desktop` alias) | `surface` |
| `qt.section` | `home` `explore` `songs` `albums` `artists` `liked` `history` `playlist:<id>` (`pl-1`…`pl-7`) | `section` |
| `qt.stageLayout` | `standard` · `lyrics-only` · `art-only` | `stageLayout` |
| `qt.stageBackground` | `blur` · `cover` · `vinyl` · `video` · `visual` | `stageBackground` |
| `qt.theme` | `auto` · `light` · `dark` | `theme` |
| `qt.account` | `premium` · `free` | `account` |
| `qt.translation` | `auto` · `off` · `zh-Hans` `zh-Hant` `en` `ko` `ja` `vi` `es` `fr` `de` | `translation` |
| `qt.lang` | `auto` · `en-US` · `zh-CN` (or `-AppleLanguages "(zh-Hans)"`) | `lang` |
| `qt.track` | mock id, e.g. `ne34516548` (default: first Liked song) | |
| `qt.time` | seconds (default `31.5`) | |
| `qt.paused` | bool (default **YES** — launches never start playback by themselves) | |
| `qt.panelTab` / `qt.panelHidden` | `now-playing` · `queue` / bool | |
| `qt.videoMode` | bool | |
| `qt.ad` | bool — force the ad state (simulated engine) | `playAd` |
| `qt.screen` | display-name substring; debug builds default to `U270CA` | |
| `qt.window` | `1440x900` (default) | |
| `qt.show` | comma list: `mini`, `desktopLyrics`, `menuBarPopover`, `settings` | |
| `qt.readyFile` | path; JSON `{pid, bundleID, windows:[{identifier, number, title, frame}]}` when settled | |
| `qt.catalog` | mock catalog folder override (also `$QT_MOCK_CATALOG`) | |

Builders add their own as `qt.<area>.<name>` (e.g. `qt.stage.chrome hidden`, `qt.lyrics.scrolled YES`), read with
`model.launch.string/bool/double("qt.stage.chrome")`, and list them here.

| Area | Keys |
|---|---|
| window | `qt.window.search <text>` · `qt.window.page album:<title>\|artist:<name>\|mood:<id>` (e.g. `mood:genre:Pop`, `mood:mood-relax`) · `qt.window.scroll <pt>` (Explore / artist / mood pages) · `qt.library.filter <text>` · `qt.library.scroll <pt>` (300 pins the compact header) · `qt.library.sort title\|album\|artist\|time\|added[:desc]` · `qt.library.select 1,3` · `qt.home.scroll <pt>` |
| player | `qt.player.upNext demo\|id,id` · `qt.player.autoplay NO` · `qt.player.shuffle YES` · `qt.player.repeat off\|all\|one` · `qt.player.adElapsed <s>` (with `qt.ad`: run the ad `<s>` s then pause; 2 = "Skip in 3", 6 = skippable) · DEBUG `qt.player.keyAppearance YES` (best-effort key-window rendering in background captures; check the shot and retake) |
| lyrics-ui | `qt.lyrics.scrolled` · `qt.lyrics.options` · `qt.lyrics.demoVersions` · `qt.lyrics.translationState same\|translating\|download\|unavailable\|onDevice\|appleIntelligence` · `qt.lyrics.lab` · `qt.lyrics.debug` |
| stage | `qt.stage.chrome hidden` · `qt.stage.queue YES` · `qt.stage.popover appearance` · `qt.stage.window YES` (detached window) · `qt.stage.reduceMotion YES` · `qt.stage.visualizerOnBattery YES` · `qt.stage.closeAfter <s>` |
| desktop | `qt.desktop.miniMode compact\|art` · `qt.desktop.miniLyric` · `qt.desktop.miniHover` · `qt.desktop.lyricsUnlocked` · `qt.desktop.menuBarScroll` · `qt.desktop.lyricsSize <pt>` · `qt.settingsTab general\|playback\|lyrics\|account\|advanced`; DEBUG: `qt.desktop.switchLanguage`, `qt.desktop.popUpMenu <index>`, `qt.desktop.showShortcuts` |

Env-gated test suites: `QT_LIVE=1` (live anonymous InnerTube / lyrics / playback), `QT_RECORD=1` (re-record
InnerTube fixtures), `QT_DUMP=1` (print parser output), `QT_KEYCHAIN_TEST=1` (Keychain round trip).

## Scripts

- `Scripts/make-mock-catalog.py` — `design/prototype/data.js` + `assets/` → `Generated/MockCatalog/`
  (`catalog.json`, `covers/`, `mv/`) in the **main checkout**. Git-ignored: copyrighted covers/lyrics. 12 tracks
  (one region-locked, two without MV), 5 with lyrics (2 word-synced with zh translation), Liked (`LM`) + 7 playlists
  (`pl-1`…`pl-7`, names from the prototype sidebar), Home moods + 4 shelves.
- `Scripts/build-app.sh` — builds and assembles `.build/apps/QTube Music.app` (bundle id `com.roderickqiu.qtube`,
  macOS 15, `en` + `zh-Hans`, SwiftPM resource bundles in `Contents/Resources`, mock catalog, ad-hoc signed).
  `QT_VARIANT=<name>` → `QTube Music <name>.app`, `com.roderickqiu.qtube.dev-<name>`, scratch `.build/<name>`,
  so agents run side by side. `QT_CONFIG=release`, `QT_SCRATCH=…`. `--print-path`. Works from worktrees.
- `Scripts/shoot.sh <outname> [--window main|mini|desktopLyrics|menuBarPopover|settings]… [launch args]` —
  quits that variant, `open -g -n` with `-qt.screen U270CA -qt.readyFile …`, waits for the ready file, finds window
  ids with `Scripts/tools/qt-window-id.swift` (compiled to `.build/qt-tools/`, CGWindowList by pid + title; Settings
  via the ready file because its title is the localized tab name), `screencapture -l<id> -o -x` into the main
  checkout's `screenshots/<outname>.png` (+ `<outname>-<window>.png`), quits, restores the frontmost app if it
  moved. Retakes a capture that Stage Manager shrank or caught mid-animation (narrower than the window or nearly
  empty). `QT_KEEP=1` leaves it running; `QT_BUILD=1` builds first. Prefix outnames with your area.
- `Scripts/shoot-region.sh` — screen-region capture on U270CA (mini player, unlocked desktop lyrics); other
  windows on that display can show at the edges. `Scripts/tools/qt-composite.swift` composites a transparent
  window capture over system wallpapers (desktop-lyrics shots).
- `Scripts/make-app-icon.sh` (`Scripts/tools/qt-make-icon.swift`) — renders `Assets/AppIcon.icns` (macOS 15–25)
  and the Icon Composer `Assets/AppIcon.icon` that `build-app.sh` compiles with actool (`Assets.car`).
- `Scripts/contact-sheet.sh <outname> [--title T] [--columns N] <img> <caption>…` — one captioned PNG in
  `screenshots/` (AppKit, offline).

## Rules for every builder

- Never take focus or the main screen: only `open -g` (`-n`), no `NSApp.activate` in launch paths, panels are
  non-activating; check the frontmost app after launching and hand it back. Drive UI by launch args, AX or
  in-process hooks — no synthetic clicks.
- Build with a private scratch path: `swift build --scratch-path .build/<you>`, `swift test --scratch-path .build/<you>`,
  `QT_VARIANT=<you> Scripts/build-app.sh`.
- Screenshots only in the main checkout's `screenshots/` (no new folders). Commit locally, never push. Never
  commit secrets, cookies, covers, MV stills, lyrics or generated catalogs.
- Naming: every public type starts with `QT`; identifiers and accessibility ids are area-specific
  (`qt.stage.background.vinyl`, not `stage`/`mini`). Two real bugs came from reused generic names.
- Swift 6 strict concurrency; UI types `@MainActor`; macOS 26 APIs (Liquid Glass, Foundation Models) behind
  `if #available(macOS 26, *)`. Keep real audio muted in tests.
- Ask-before (record as gaps, don't do): writing to the user's YouTube Music account, using their session,
  new third-party dependencies, Developer ID/notarization, sending user data anywhere.

## Tests

Swift Testing (`import Testing`, `@Test`, `#expect`). One test target per module:
`QTCoreTests` (models, queue, lyrics, settings, catalog, localization + catalog coverage), `QTPlaybackTests`
(simulated engine with an injected clock — no sleeps), `QTLyricsTests` and `QTInnerTubeTests` (recorded fixtures
go in their `Fixtures/` folders, accessed with `Bundle.module.url(forResource: "Fixtures", withExtension: nil)`;
record only anonymous public responses, no user data), `QTUITests` (launch options, SF Symbols, theme).
Tests must pass offline and without the git-ignored catalog. Run: `swift test --scratch-path .build/<you>`.
