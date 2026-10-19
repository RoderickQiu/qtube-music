# QTube Music — architecture

The contract for everyone building on the scaffold. Spec: `docs/redesign-draft.md` (v0.2). Visual source of
truth: `design/prototype/` (layout, copy, states). Native macOS look and behaviour override pixel-matching the
prototype (see *Native UI rules*).

## Modules

SwiftPM package `QTubeMusic` (`Package.swift`, tools 6.2, Swift 6 language mode, macOS 15).

| Target | Depends on | Contents | Owner |
|---|---|---|---|
| `QTCore` | — | Models (`QTTrack`, `QTAlbum`, `QTArtist`, `QTPlaylist`, `QTShelf`/`QTHomeFeed`, `QTArtworkPalette`), `QTQueue`, `QTLyricsDocument`, `QTSettings` + `QTSettingsStore`, `QTMockCatalog` + `QTCatalogService`, `QTFormat`, `QTLoc` localization, **all String Catalogs** | shared (scaffold) |
| `QTInnerTube` | QTCore | `QTInnerTubeClient` (actor: ytcfg scrape, WEB_REMIX context, hl/gl, SAPISIDHASH, TTL+LRU cache, retries, session-loss detection; account writes gated by `setAllowsAccountWrites`), parsers → QTCore models (music-only filter), `QTCounterpartResolver` (Song⇄Video), `QTInnerTubeCatalog` (`QTCatalogService`), `QTInnerTubeConfiguration`; `Lyrics/QTInnerTubeLyricsClient` (anonymous ANDROID_MUSIC `post(_:payload:)` for timed lyrics, follows a client's hl/gl/visitor id — lyrics-live) | data-layer |
| `QTAuth` | QTInnerTube | `QTAuthController` (`restore()`, `beginSignIn(hl:over:)`, `signOut()`, `webDataStore`, DEBUG-only session import), `QTSessionStore` (actor, Keychain `com.roderickqiu.qtube`), `QTAuthSession`/`QTCookie` (auth-cookie allowlist), `QTWebCookieStore` (`QTWebKitCookieStore.session`: the non-persistent jar playback uses), `QTLegacyWebStorage` (deletes old plain-text WebKit data), `QTAuthState` | data-layer |
| `QTPlayback` | QTCore, QTInnerTube | `QTPlaybackEngine` protocol, `QTSimulatedPlaybackEngine`, `QTQueueController` (queue + context, shuffle/repeat, autoplay continuation, persistence via `QTQueueStore`, holds a process activity while playing), `QTNowPlayingController` (sole owner of Now Playing + remote commands), `Web/QTWebPlaybackEngine` (hidden WKWebView in the non-persistent session jar `QTWebKitCookieStore.session`, `sessionDidChange()`, JS bridge, ads, playability errors, offline recovery, 144p decode, page freeze while paused; `QTWebKitTuning` keeps the hidden page scheduled), `Web/QTWebVideoOutput` (M5: the page's music video in app views, native PiP, `QTModeSwitchReport`), `QTPlaybackEngineSelector`, `QTNativePlaybackEngine` stub (M5, `isAvailable = false`); `Native/` = M5 spike code, not used by the app (`QTNativeStreamResolver` + `QTNativeStreamClient` table, `QTNativePlayerScript` sig/n solving in JavaScriptCore, `QTNativeAudioGraph` AVAudioEngine gapless/crossfade/10-band EQ/FFT tap, `QTNativeStreamDownloader`, `QTNativeAVPlayerProbe`) — see `docs/native-engine-spike.md` | playback (Web video parts: stage-video); Native/: native-spike |
| `QTDevSession` | QTAuth | DEBUG-only executable: import the dev session from CDP cookie JSON on stdin; read-only `status` / `summary` / `probe` / `ytcfg` (never prints cookie values) | data-live |
| `QTPlaybackLab` | QTPlayback | dev-only executable: drives the web engine live, muted and anonymous (`swift run --scratch-path .build/<you> QTPlaybackLab --scenario basic`) | playback |
| `QTNativeSpike` | QTPlayback, QTAuth | DEBUG-only executable for the M5 spike: `clients` / `bench` / `cipher` / `avplayer` — stream resolution per client, download → AVAudioEngine (muted), TTFA, CPU, gapless, crossfade, EQ, spectrum; `--signed-in` reads the shared dev session (never prints cookie values). Downloads the EJS solver and audio into `~/Library/Caches/com.roderickqiu.qtube.native-spike/` (audio purged after each run) | native-spike |
| `QTLyrics` | QTCore | `QTLyricsResolver` (actor, `QTLyricsProviding`): parsers (LRC, YRC, QRC, KRC, TTML), QRC/KRC decryption, providers (YouTube Music, LRCLIB, AMLL; NetEase/Kugou/QQ opt-in), matcher, `QTLyricsCache` (SQLite), romanization, translation (selector, coordinator, Apple Intelligence + Translation framework engines); `QTMockLyricsProvider` | lyrics |
| `QTIntegrations` | QTCore | Opt-in integrations, all off by default: Last.fm (`QTLastFMRequest` signing/requests, `QTLastFMClient`, `QTScrobbleRules`, `QTListenTracker`, `QTScrobbleQueue` offline queue, `QTScrobbler` actor), Discord Rich Presence (`QTDiscordIPC` framing, `QTDiscordActivity`, `QTDiscordPresence` socket actor), `QTIntegrationsSettings` + `QTIntegrationsStore` (defaults `qt.integrations.v1`; secrets in the Keychain via `QTKeychainSecretStore`) | desktop |
| `QTUI` | all | SwiftUI/AppKit UI, app model, theme | per folder, below |
| `QTubeMusicApp` (product `QTubeMusic`) | QTUI, Sparkle | `@main` app: `Window` (main), `Settings`, `MenuBarExtra`, `QTCommands`, app delegate (Dock menu, AppleScript application properties), `QTAppIntents.swift` (App Intents + App Shortcuts), `QTUpdater.swift` (Sparkle, dormant); `Resources/` (sdef, intent String Catalogs — excluded from SwiftPM, put in the bundle by build-app.sh) | desktop |

Spec names → types: PlaybackEngine = `QTPlaybackEngine`, QueueController = `QTQueueController`,
NowPlayingController = `QTNowPlayingController`, WebPlaybackEngine = `QTWebPlaybackEngine`.

**One third-party dependency: Sparkle** (approved; only the app target links it). LyricsKit was dropped at
integration: its QRC/KRC/YRC parsers and decrypters are not public, so `QTLyrics` has its own (zlib and sqlite3 come
from the system). Do not add any other dependency without asking the user.

### What runs today (after integration)

Everything is wired (integration of M1 polish + M2–M4):

- **Catalog:** live by default (data-live, M3). `QTLiveCatalogStore` restores the saved session and loads the user's
  YouTube Music library; signed out, the content column shows a native signed-out state with Sign In / Use Demo
  Library. `-qt.catalog mock` (the default in `Scripts/shoot.sh`) keeps `QTMockCatalog` and never touches the
  Keychain. `QTLiveCatalogStore.wantsLive(launch)` is the one decision; bootstrap also uses it for playback.
  **Mode transitions** (`QTLiveCatalogStore.authStateChanged`, the one place): signed in while signed out (signed-out
  screen, Settings, or again after expiry) → pages reset and reload; signed out → signed-out screen; session expired
  → the signed-out screen ("Signed out of YouTube Music" + Sign In), never every page failing on its own. "Use Demo
  Library" is remembered (`qt.data.demoLibrary`), but a demo launch still restores the account (Settings › Account
  shows it) and any session — restored or a new sign-in — clears the choice and switches to the library
  (`QTPlaybackServices.switchSource(to:)`: web engine with the session, Now Playing, queue persistence; the demo
  plays through the simulated engine and never overwrites the saved queue). Choosing the demo on an expired session
  signs out (a dead session can't come back). Only `-qt.catalog mock` (or a catalog path) never reads the Keychain.
  Page failures: only connectivity errors (`QTInnerTubeError.isConnectivity`) read as offline; a cancelled load
  (account switch) returns the page to idle instead of a failure state.
- **Lyrics:** `QTLyricsSession` (M2, below) resolves every track through `QTLyricsResolver` — the one source every
  surface reads (`player.lyrics` forwards to it; `QTAppModel.resolvedLyrics` adds the translation lane). Mock tracks
  are matched by title/artist/duration; bundled mock lyrics are the offline fallback, or the whole source with
  `-qt.lyrics.engine mock` (shoot.sh's default with the mock catalog). Unofficial sources are opt-in, so a default
  live launch shows no lyrics for the mock hero track; the mock-source settings override applies only with
  `-qt.lyrics.engine mock`.
- **Playback:** `QTPlaybackSetup` / `QTPlaybackServices` (`QTUI/AppModel/QTPlaybackSetup.swift`, builder "playback"),
  with `source: .live` whenever the live catalog is wanted. Live playback is **signed in** (approved): the web engine
  plays in QTAuth's session jar, so Premium plays without ads and plays are recorded in the user's YouTube Music
  history. `-qt.playback.anonymous YES` opts out. Sign-in / sign-out mid-session → `QTWebPlaybackEngine.sessionDidChange()`
  (the next load navigates a fresh page; the current item reloads at its position).
- **Autoplay:** with the live library, `QTQueueController.autoplayContinuation` is YouTube Music's radio for the
  last track (`next` with `RDAMVM<id>`, read-only), installed by `QTLiveCatalogStore` on entering live mode.
  Lyrics' `QTInnerTubeLyricsClient` follows the app client's hl / gl / visitor id (still anonymous).
- **Account:** `model.authController` is the live store's `QTAuthController`; Settings › Account (desktop) shows its
  state and signs in/out through the store.

- **Engine:** `QTPlaybackSetup.resolve(launch:source:tier:)` — mock data → `QTSimulatedPlaybackEngine`; real data
  (`source: .live`) → `QTWebPlaybackEngine` for free *and* Premium until the native engine ships (M5).
  `-qt.engine web` plays the mock catalog through the web engine using each track's real MV id
  (`catalog.mv.videoId`); tracks without one keep their made-up id and fail like a removed video (toast + skip).
  Mock data through the web engine is always anonymous (non-persistent data store) and silent (media volume pinned
  to 0) unless `-qt.playback.silent NO`.
- **Now Playing:** `QTNowPlayingController` is created for any real engine (sole owner; stays inactive until
  playback actually starts). Media runs in the WebContent process so WebKit never adds a second entry
  (verified: `Scripts/now-playing.sh clients`).
- **Queue persistence:** `QTQueueStore` only for real data in unscripted runs (`-qt.readyFile` / status-file runs
  never persist); flushed synchronously on quit; `applyLaunchPlayback` restores it when there's no `-qt.track`.
- **Launch playback runs once per process** (`QTAppModel.applyLaunchPlayback`, flag `didApplyLaunchPlayback`): the
  main window's first `.task` and the live store (after the session is restored, and once Liked arrives) may all call
  it; it waits while the session restores (the player page must start signed in), waits for Liked when there is
  nothing to cue, and never runs again after it cued something — so reopening the main window (Dock, ⌘0, menu bar)
  never touches playback. Without `-qt.time` the track is cued at 0; scripted runs (`-qt.readyFile`) default to 31.5 s.
- **Failures:** `QTQueueController.onFailure` → toast (`Playback` table): age-restricted / not available in your
  region / not available / didn't load / couldn't play — skipped; "Playback stopped" after 3 in a row. Offline →
  one toast; the engine resumes the item when the network returns.
- **Buffering:** `QTPlayerModel.isBuffering` → `qtBufferingIndicator` (Shared/) swaps the play glyph for a system
  spinner after 0.45 s.


**Live data (data-live).** `QTLiveCatalogStore.shared` (attached in `QTAppModel.bootstrap`) owns the client and
`QTAuthController`, a `QTCatalogMode` (`mock` / `restoring` / `signedOut` / `live`) and per-page `QTLivePhase`s.
`QTContentRouter` hands destinations to `QTLivePage` (AppModel/Live/) when `handles(_:)` says so: live Home (mood
chips filter the feed), Liked and playlists (first page at once, continuation pages stream in), library Songs /
Albums / Artists. **Browse pages are one shared set** (window, Shell/QTBrowsePages.swift + QTSearchResultsView.swift)
for the demo and the live library: Explore (segmented Overview / New releases / Charts / Moods & genres), mood
pages, album pages (QTLibraryView), artist pages (hero or portrait, Songs, then the page's rows incl. **Videos**),
grouped search (top result + songs, then Videos / Albums / Artists / Playlists rows; music only). They read
`QTBrowse.service` — `QTLiveBrowseService` (Shell/) forwards to this store's loaders/caches/phases when live.
Album/artist destinations carry browse ids when known (`QTDestination.album(QTAlbumRef)` / `.artist(QTArtistRef)`
pick `id ?? title/name`); names are resolved through seen tracks or a search. Every page has a skeleton (`QTLiveSkeleton`, the page's
real layout, quiet pulse) and a failure state (`QTLiveFailureView`: offline / signed out / unavailable + one
action). Album, artist and playlist cards prefetch their page on hover. `hl` follows the interface language
(pages reload on change); `gl` and Premium come from the signed-in web client's `ytcfg` (`INNERTUBE_CONTEXT_GL`,
`IS_SUBSCRIBER`) via `QTInnerTubeClient.accountContext()`, and set `QTAppModel.account` unless `-qt.account` is
given. Read-only: account writes stay disabled; likes / playlist edits remain session-only.

**Session storage.** The session lives in the Keychain and, in memory only, in WebKit:
- **Never a persistent WebKit store.** WebKit saves `WKWebsiteDataStore.default()` cookies in plain text
  (`~/Library/HTTPStorages/<bundle id>.binarycookies`, 0644). The app uses none: sign-in runs in a fresh
  `.nonPersistent()` store per attempt — the login is moved to the Keychain and the throwaway cleared; playback runs in
  `QTWebKitCookieStore.session`, a process-wide `.nonPersistent()` jar seeded from the Keychain by `restore()` /
  sign-in and emptied by sign-out. `QTAuthController` refuses to write session cookies into a persistent jar, and
  `QTWebPlaybackEngine` refuses a persistent store (precondition). Rotation flows both ways: the jar's
  `WKHTTPCookieStoreObserver` (2 s settle) folds the page's rotated auth cookies of the same login (same SAPISID) back
  into the Keychain; `Set-Cookie` on API responses (`QTSessionEvent.cookiesRotated`) is copied into the jar.
  `QTLegacyWebStorage.purge()` (every launch, from `QTLiveCatalogStore.attach`) deletes what older builds left:
  `HTTPStorages/<id>.binarycookies`, `HTTPStorages/<id>/`, `WebKit/<id>/`, `Caches/<id>/WebKit` — only for bundle ids
  `com.roderickqiu.qtube*`, files only (the default store is never loaded).
- **Session loss.** A 401/403 on a signed-in request expires the session only when a probe confirms it: a signed-in
  GET of music.youtube.com whose `ytcfg` says `LOGGED_IN: false` (one probe at a time, answer reused 60 s). A probe
  that loads signed in or fails keeps the session and the request fails as `.http(status)`. A signed-in browse/next/
  search answered `logged_in=0` still expires at once.
- **Keychain.** Release builds: the normal per-app item (`QTKeychainStore`). DEBUG builds: `QTDevSharedKeychainStore` —
  service `com.roderickqiu.qtube`, account `youtube-music-session.dev`, shared by every dev variant and the
  integrator's app, created through `/usr/bin/security` so a rebuilt ad-hoc app never shows a Keychain dialog (ad-hoc
  builds get a new `cdhash:` partition each build; the tool's `apple-tool:` partition is stable). Items are created
  with `-T /usr/bin/security` (marker `qt-dev-shared-v2`): the tool is the only application on the access list, so
  another app reading the item through the Security framework gets a Keychain prompt. The first format used `-A`
  ("any application": any app could read the session silently); v1 items are rewritten as v2 on first read. Items
  are never updated in place (that wakes SecurityAgent); secrets pass only through pipes.
  **What's left, and why.** A process of the same user can still run `/usr/bin/security find-generic-password -w`
  itself and read the dev item without a prompt. No prompt-free mechanism closes that for ad-hoc builds: the item
  has to be readable by a build whose code identity changes every build, so nothing can tell it from any other local
  process. Considered and rejected: a self-signed dev signing identity (signing needs the key's partition list set
  with the login-keychain password, i.e. a dialog; and without a Team ID the Keychain still partitions by `cdhash`, so
  every rebuild would prompt anyway); encrypting the value with a key in a second item (that item must be equally
  prompt-free to read, so it adds obscurity, not protection); the data-protection keychain (needs a Team ID
  entitlement). Real fixes are user-gated: a Developer ID / Team ID-signed dev build (stable `teamid:` partition, the
  normal per-app item), or a dedicated test Google account for dev builds. Release builds are unaffected.
- `QTDevSession` (DEBUG executable) imports CDP cookie JSON from stdin (`import`) and has read-only
  `status` / `summary` / `probe` / `ytcfg` commands for exploring signed-in responses — never prints cookie values.
  `QTCookie.decodeCDP` and `QTLyricsDebug`'s /tmp log are compiled into DEBUG builds only.

## QTUI folder ownership

| Folder | Builder | Holds |
|---|---|---|
| `Shell/`, `Sidebar/`, `Home/`, `Library/` | window | main window layout, router, sidebar, Home, playlist/library tables |
| `NowPlaying/`, `PlayerBar/`, `Queue/` | player | docked inspector, player bar, `QTScrubber`, `QTTransportControls`, `QTQueueList` |
| `Lyrics/` | lyrics-ui | `QTLyricsView`, `QTLyricsOptionsButton` / `QTLyricsOptionsPopover` |
| `Stage/` | stage | `QTStageView` (layouts × backgrounds, chrome, drawer) |
| `Desktop/`, `Commands/`, `Settings/`, `Sources/QTubeMusicApp`, `Assets/AppIcon.icns` | desktop | mini player, desktop lyrics, menu bar, `QTDesktopCoordinator`, Dock menu, sidebar playlist context menu (`QTSidebarContextMenu`), `QTIntegrationsCoordinator` (Last.fm / Discord / notifications), `QTScripting` (AppleScript), menus + key routing, Settings (incl. Integrations, `QTInterfaceLanguageSync`), app icon |
| `Theme/`, `Shared/`, `AppModel/` | shared | builders may **add**; don't rename, repurpose or break existing API |
| `AppModel/QTLiveCatalogStore.swift`, `AppModel/Live/` | data-live | live catalog wiring, signed-out / skeleton / failure states, live Home, live library pages (browse pages are window's shared set) |

Edit only your folders and your String Catalog table. Need a change in someone else's area or in a shared
signature? Add a defaulted parameter or a new type in your own folder, and say so in your report.

## Shared APIs (frozen signatures)

State (environment, `@MainActor @Observable`):
- `QTAppModel` — `@Environment(QTAppModel.self)`. `surface` (`.window/.stage/.mini`), `sidebarSelection`
  (`QTSidebarItem`), `selectedTrackIDs`, `isPanelShown`, `panelTab` (`.nowPlaying/.queue`), `isVideoMode`,
  `account` (`.premium/.free`), `searchText`, `toast` + `showToast(_:undo:)`, persisted shortcuts `stageLayout`,
  `stageBackground`, `theme`, `lyricsTranslation`, `isDesktopLyricsShown`, `resolvedTranslationLanguage`, `palette`,
  `catalog` (`QTMockCatalog`), `settings` (`QTSettingsStore`), `launch` (`QTLaunchOptions`), `authController`
  (`QTAuthController?` — the data-live wiring sets it; Settings › Account reads its `state`/`account` and creates one
  on demand when the user presses Sign In). One per process: `QTAppModel.shared`.
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
  `.mini`, `.desktop`. `onSeek` gets a playback time. Lanes (translation / romanization) are drawn in the main ink
  and get their level from `QTLyricsMetrics.laneOpacity(rowOpacity:)`: ~0.62–0.66 beside the current line
  (secondary), rising to 0.86 of a dimmed row's own opacity (≈ tertiary) — never lane alpha × row alpha.
- `QTLyricsOptionsButton(overArt:)` → system popover with `QTLyricsOptionsPopover()` (source + timing kind of what is
  showing, Translate to + status, one "Unofficial sources" switch — per-provider switches live in Settings › Lyrics —,
  timing stepper, Other versions with an "Automatic" entry that unpins). Opening it re-checks a translation that
  waited for a download / Apple Intelligence and retries an unreachable lookup.
- Machine translation (M6, `QTLyricsTranslationCenter`, Lyrics/QTLyricsTranslation.swift): provider lane in the
  target → Apple Intelligence (`QTAppleIntelligenceTranslationEngine`, Foundation Models, macOS 26+, only when
  Settings' "Translate lyrics with Apple Intelligence" is on and `SystemLanguageModel` is available and supports the
  target; guided generation with a `@Generable` result whose schema fixes exactly one string per source line; chunks of
  ≤24 lines / ~900 chars with title, artist and the 4 previous lines as context; permissive-transformation guardrails;
  45 s per chunk) → Translation framework (`QTTranslationFrameworkEngine`: direct `TranslationSession(installedSource:)`
  on macOS 26+, SwiftUI-hosted `.translationTask` session before that; a missing model is `.needsDownload` and only the
  popover's "Download {language}…" button starts the system's consent/download). Refusal, wrong line count, an
  untranslated echo or timeout falls back to the Translation framework for the whole song — never partial. Results
  are cached in the lyrics SQLite (`translations` table) under `lyrics:<FNV-1a of the lines>` + language + engine;
  jobs belong to the center (they survive the view that asked). `QTLyricsTranslationCoordinator` (QTLyrics) holds the
  engines, validation (`QTLyricsTranslationValidator`) and the cache. Popover labels the engine ("Apple
  Intelligence" / "On-device translation" / provider) and says "Song is already in …" when it skips.
- `QTLocalizedAppKitText` / `NSView.qtLocalizedAccessibility(_:toolTip:)` / `NSWindow.qtLocalizedAccessibility(_:)`
  (Lyrics/QTLocalizedAppKitText.swift): AppKit accessibility labels and tooltips that follow a live language switch.
  Use instead of a one-shot `setAccessibilityLabel(QTLoc.tr(…))` in AppKit inits.
- `QTAppModel.resolvedLyrics` → `QTResolvedLyrics` (Lyrics/): the document + the **one** translation lane every surface
  shows (`translation(forLine:)`, `currentLine(atPlaybackTime:)` → line + translation, `isInstrumental(atPlaybackTime:)`,
  `translationStatus`). Never read `QTLyricsLine.translation` in a view: it is the provider's lane in whatever language
  the provider shipped. Surfaces that show a translation without a `QTLyricsView` add `.qtHostsLyricsTranslation()` so
  on-device translation runs for them too.
- `QTQueueList(style: .panel | .stageDrawer)`.
- `QTTransportControls(style: .playerBar | .stage | .compact)` (`.stage` draws play/pause as a filled disc via
  `QTStagePlayButtonStyle`, Stage/); `QTScrubber(overArt:identifier:)` (an `AXSlider` to VoiceOver / Voice Control via
  `accessibilityRepresentation`; identifier default `qt.player.scrubber`, the Stage passes `qt.stage.scrubber`).
- `QTSongVideoToggle(isVideo:hasVideo:)` — segmented Picker.
- `QTToastOverlay()`, `QTIcon` (prototype icon name → SF Symbol; test checks every symbol exists).
- `QTNowPlayingIndicator.symbolName/image(isPlaying:)` + `QTNowPlayingGlyph(isPlaying:)` (Shared/) — the one marker for
  the current track in tables and lists: speaker only while playing, pause glyph while paused.
- `QTAdTint.color(overArt:increasedContrast:)` (PlayerBar/) — the amber ad colour (scrubber fill + "Ad" label).
- Window plumbing: `QTWindowID` (identifiers + capture titles), `QTWindowAccessor`, `QTWindowPlacement`,
  `QTReadiness` (`hold`/`release` around anything async the first frame needs). The main window keeps the user's
  autosaved frame; `QTWindowPlacement.shouldPlaceMainWindow` places it only for `-qt.screen` / `-qt.window` launches
  or when no autosaved frame exists. Its NSWindow title is the current page (`QTWindowTitle`, hidden in the
  toolbar) — scripts find the main window through the ready file's identifier, not by title.

Coordinators (one per process, `@MainActor`):
- `QTNavigator.shared` (Shell/) — content-column navigation: `go(.section(…) | .album(…) | .artist(…))`,
  `goBack`/`goForward` (history 64), per-page list state, `requestSearchFocus()` / `requestFilterFocus()`. Navigate
  through it so moves enter history; setting `model.sidebarSelection` still works.
- `QTStageCoordinator.shared` (Stage/) — `toggleStage(model:)` (⇧⌘F; closes a detached Stage), `showDetached(on:model:activate:)`,
  `returnToMainWindow(model:)`, `isDetached`, `otherScreens(than:)`. The Stage offers the display moves in its
  right-click menu (no ⋯ button).
- **Song⇄Video (M5, stage-video).** `QTVideoModeService.shared` (NowPlaying/) keeps the loaded rendition in step with
  `model.isVideoMode` (the intent: the Song | Video switch, ⇧⌘V, the Stage's Video swatch; starts from and follows
  Settings › "Prefer videos when available"), installs `QTQueueController.counterpartResolver` (InnerTube `next`, then
  `QTCounterpartMatcher` search; anonymous, read-only; current + next track) and owns ⇧⌘P
  (`togglePictureInPicture()`, `canTogglePictureInPicture`, `isPictureInPictureActive`). `QTQueueController.preferredMode`
  carries the choice across tracks; `setMode` reloads the counterpart at the current position (queue untouched).
- **Live video:** `QTLiveVideoView(kind: .panel | .stage, cornerRadius:) { placeholder }` (NowPlaying/) shows the web
  engine's real video with the placeholder (artwork / MV still) on top until the first frame, then crossfades
  (0.32 s); ads, PiP and the simulated engine show the placeholder (PiP adds a quiet `pip` glyph).
  `QTVideoSlotCoordinator` gives the one video to the highest visible slot (Stage > panel); none → the page goes back
  to the hidden host at 144p. `QTWebVideoOutput` (`engine.video`): `present(in:)` / `withdraw(from:)`, `hasFrame`,
  `isPictureInPictureActive`, `setPictureInPicture(_:)`, quality per slot (`small` panel … `hd1080` Stage). How it
  works: the WKWebView moves into the slot (one reparent, window to window; the engine resumes playback if WebKit
  pauses the page on the way back into the hidden host); the `videoSurface` script hides all page UI and draws each
  decoded frame on one canvas (WebKit's inline video layer stays blank after the view changes windows), cropping
  burned-in letterbox bars; the page never takes clicks, focus or VoiceOver (`QTWebPlaybackView`); content insets
  are zeroed so the video runs under the title bar. Native PiP is WebKit's (`_allowsPictureInPictureMediaPlayback`).
- `QTStageVideoSurfaceProvider.shared.source` (Stage/) — a native engine can still hand the Stage its own
  `.layer(AVPlayerLayer)` / `.view(NSView)`; otherwise the Stage's Video background is `QTLiveVideoView(kind: .stage)`.
  Lyrics over the video are optional (Appearance popover › "Lyrics over video", `@AppStorage("qt.stage.videoLyrics")`).
- In-window Stage keeps the window's own title bar and SwiftUI toolbar (so the traffic lights stay put and the
  inspector's toolbar plumbing stays consistent): Shell drops its toolbar items while `surface == .stage`, and
  `QTStageTitlebar` (Stage/) hides every remaining toolbar item (`NSToolbarItem.isHidden`, also items SwiftUI adds
  later) and shows exactly those again on close. (Swapping in an empty `NSToolbar` made showing the panel under the
  Stage loop AppKit's constraint pass until it crashed.) Under the Stage the browsing UI is `accessibilityHidden`,
  takes no hits and is disabled (after the fade-in), so VoiceOver and Full Keyboard Access only reach the Stage.
- `QTDesktopCoordinator.shared` (Desktop/) — mini player, desktop lyrics (hidden while the Stage is up, inline or
  detached; until the user moves it, its default spot steps out of the main window's way), menu bar title, Dock
  menu, `showMainWindow()` (user-initiated only).
- `QTLyricsTiming.nudge(model, by:)` (Lyrics/) — offset change + toast; `QTLyricsVersionStore.shared`.
- `QTLyricsSession` (AppModel/QTLyricsSessionService.swift, lyrics-live) — **the one lyrics source of truth**, one per
  app (`model.lyricsSession` = `player.lyricsSession`; `player.lyrics`/`isLoadingLyrics` forward to it). Publishes
  `phase` (idle/loading/loaded/notFound/unreachable), `document` (offset applied; translation lane only when it is in
  the current target and the song isn't already in it; zh-Hans lane converted for a zh-Hant target), `fullDocument`,
  `syncKind`, `sourceName`, `attribution`, `versions`/`otherVersions`/`chosenVersionID`/`isPinned`,
  `isPossibleMismatch`, `translationPlan`/`translationTarget`/`translationEngineName`, `romanizationSource`/
  `hasRomanization`, `offset`, `unreachableSources`, `isShowingFallback`. Actions: `load(_:)` (track change),
  `reload()`, `retryIfUnreachable(force:)`, `networkDidChange(available:)` (own `NWPathMonitor`; coming back online
  re-runs an `.unreachable` lookup; `isNetworkAvailable` lets the empty state say "Offline" rather than "No lyrics",
  or "Can’t reach lyrics" + Try Again when online), `pin(versionID:)`/`unpin()` (persisted; also wired to `QTLyricsVersionStore.onPin`),
  `nudgeOffset(by:)`/`setOffset(_:)` (live, persisted per track, debounced). Reacts to Settings (unofficial sources,
  translation target, interface language) by itself. All network/SQLite work is off the main actor.

Keyboard ownership: `QTCommands` (Commands/) is the only menu definition — every shortcut is bound once there
(navigation items call `QTNavigator`); ⌘1–7 follow the sidebar (Home … History). **Space** in any of our windows is
decided by `QTKeyRouting` (Commands/; `QTWindowKeyMonitor` in Shell/ only forwards to it): with nothing focused, a
table/outline (track lists, sidebar) or a scroll view focused, it plays/pauses at once; otherwise the focused view gets
it first (text fields, every `NSControl` incl. switches/steppers, SwiftUI-focused controls via their focus proxy) and
only a Space that falls off the end of the responder chain unused (`QTUnusedKeyCatcher`) plays/pauses. The menu's
Space key equivalent is display-only. ⌘←→ / ⌘↑↓ / ⌥↑↓ go to a text field being edited, else the menu. Esc is handled
inside the Stage (`.cancelAction`), not in menus. File keeps one item, Close Window ⌘W (no Close in Window).

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
- `QTBrowseService` (Shell/, window, `@MainActor`): `cached(_ QTBrowseRequest) -> QTBrowseResponse?` and
  `load(_:force:) async throws -> QTBrowseResponse?` for `.explore` (`QTExploreContent`: Overview shelves + server
  section names), `.exploreSection(.newReleases|.charts)` (shelves), `.moods` (`QTMoodsPage`), `.mood(chip)`,
  `.search(q)`, `.album(key)`, `.artist(key)` — the `QTInnerTubeClient` page types; typed helpers `album(_:)`,
  `artist(_:)`, `search(_:)`. `QTBrowse.service` = `QTLiveBrowseService` (store-backed) when the live library is
  up, else `QTMockBrowseService` (demo catalog, synchronous). Pages load through `QTBrowseLoader` (cached first
  frame, skeleton, one failure state with Try Again, previous page kept while the next loads; reloads on
  interface-language or source change); `QTBrowseActions.playAlbum/playArtist/playPlaylist` fetch a page first
  when needed.
- Window controls: page buttons use `.qtGlassButton(.primary | .secondary, iconOnly:)` (Theme/QTGlass.swift);
  `QTPillButtonStyle` (capsule; primary = artwork accent fill) is its macOS 15 / Reduce Transparency fallback.
  `QTChipToggleStyle` (mood/genre chips, built on `qtGlassButton`), `QTChipFlow` (wrapping layout) — Shell/QTWindowButtonStyles.swift.
- Navigation: `QTDestination` adds `.mood(QTMoodChip)` (Explore mood/genre pages).

## Native UI rules (user requirement)

The prototype defines layout, hierarchy, copy and states; the app must look like a first-class Mac app.
- Native controls: `NavigationSplitView` sidebar (system material, source-list selection), real toolbar +
  `.searchable`, `.inspector` for the docked panel, `Table`/`NSTableView` with system headers, `Picker`
  (segmented/menu), `Toggle` (`.button` style for shuffle/repeat = filled when on), `Slider`, `Stepper`, `Menu`,
  `.popover`, grouped `Form` in Settings, `NSMenu`/`.contextMenu`, sheets/alerts.
- System semantics only: `QTTheme.Colors` wraps label/secondary/tertiary/separator/window/selection colours.
  Artwork accent is a **tint only** (`.qtArtworkTint(palette)` sets `.tint` + `\.qtAccent`; system accent under
  Increase Contrast).
- **Liquid Glass (R3).** macOS 15 stays the minimum; macOS 26+ gets glass, macOS 15 system materials, Reduce
  Transparency solid surfaces — decided in ONE place, `Theme/QTGlass.swift`. Feature code never calls
  `glassEffect` or paints `.material` backgrounds itself:
  - `qtGlass(_ role, in: shape, tint:, interactive:)` — roles `.chrome` (floating pieces over our content: toasts,
    lyrics "Current" pill), `.bar` (the player bar: glass with a neutral window-colour wash so titles stay legible
    over vivid art; in light mode it also gets a hairline + soft outside shadow so it has an edge over white
    content), `.overArt` (Stage chrome, queue drawer, ad badges, mini player art controls; dark context).
    Tint = the artwork accent at ~0.12–0.16 opacity, only over art.
  - `qtGlassButton(.primary | .secondary, iconOnly:)` — `.glassProminent` / `.glass` (capsule or circle; accent via
    `.tint`): mood chips, collection Play / Shuffle / More, search top result, panel header hide button.
  - `QTGlassGroup { … }` — `GlassEffectContainer` for neighbouring glass shapes (Stage top bar).
  - `qtFloatingBottomBar { … }` — `safeAreaBar` on macOS 26 (scroll edge effect under the bar), `safeAreaInset`
    before. The player bar floats over the bottom of content + inspector (10 pt inset, radius 22); the sidebar
    keeps the window's full height and pages scroll under the bar.
  - `QTPanelGlassBackground(cornerRadius:)` — window-level glass for clear panels (`NSGlassEffectView` on 26,
    `.popover` vibrancy before): mini player strip, desktop lyrics controls.
  - DEBUG `-qt.reduceTransparency YES` renders every primitive's solid fallback (native chrome follows the real
    setting). `qtFloatingSurface(_:material:)` remains as a forwarder to `.chrome`.
  - Native chrome — sidebar, toolbar items and search field, segmented pickers, popovers, menus, the MenuBarExtra
    window — gets the system glass by itself. Don't paint over it, don't add `.toolbarBackground`, and keep the
    toolbar/inspector/split view stock.
  - It only appears if the binary is linked on the macOS 26+ SDK: see `build-app.sh` (SDK stamp) below.
  - No `GridItem(.flexible(minimum:))` (or other hard minimum widths) in content pages: with the inspector open, a
    content minimum feeds AppKit's split-view constraints into an update-constraints loop (crash) on the macOS 26+
    design. Count columns from the measured width instead (`QTQuickPicks`).
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
  call `QTLoc.tr` re-render when `settings.interfaceLanguage` changes. System-provided menu items (Edit › Undo,
  Window › Minimize, Hide, Quit…) are localized by AppKit at launch from the app's `AppleLanguages`: picking a
  language in Settings writes it (`QTInterfaceLanguageSync`: English → `["en"]`, 简体中文 → `["zh-Hans"]`, Auto removes
  the key — the same key System Settings' per-app language uses; at launch only an explicit choice is re-applied, never
  cleared), and General shows a quiet **Relaunch** button beside
  the picker while the menus are still in the launch language. Launch arguments (`-qt.lang`, `-AppleLanguages`,
  scripted runs) never write it.
- App Intents strings live in the app target: `Sources/QTubeMusicApp/Resources/AppIntents.xcstrings` (titles,
  `LocalizedStringResource(…, table: "AppIntents")`) and `AppShortcuts.xcstrings` (Siri/Spotlight phrases); a
  QTCoreTests check keeps both translated.
- Catalogs live in `Sources/QTCore/Resources/Localization/` (one bundle for every module):

  | Table (`QTStringTable`) | File | Who adds keys |
  |---|---|---|
  | `.shared` | `Localizable.xcstrings` | all 160 prototype keys + scaffold keys; **don't add** new keys here |
  | `.main` | `Main.xcstrings` | window builder |
  | `.player` | `Player.xcstrings` | player builder |
  | `.lyrics` | `Lyrics.xcstrings` | lyrics-ui + lyrics builders |
  | `.stage` | `Stage.xcstrings` | stage builder |
  | `.desktop` | `Desktop.xcstrings` | desktop builder |
  | `.live` | `Live.xcstrings` | data-live builder |
  | `.playback` | `Playback.xcstrings` | playback builder (failure/offline toasts, "Loading") |

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
| `qt.time` | seconds (default `0`; `31.5` in scripted runs with `-qt.readyFile`, just before the hero track's first lyric) | |
| `qt.paused` | bool (default **YES** — launches never start playback by themselves) | |
| `qt.panelTab` / `qt.panelHidden` | `now-playing` · `queue` / bool | |
| `qt.videoMode` | bool | |
| `qt.ad` | bool — force the ad state (simulated engine) | `playAd` |
| `qt.screen` | display-name substring; debug builds default to `U270CA` | |
| `qt.window` | `1440x900` (default) | |
| `qt.show` | comma list: `mini`, `desktopLyrics`, `menuBarPopover`, `settings` | |
| `qt.readyFile` | path; JSON `{pid, bundleID, windows:[{identifier, number, title, frame}]}` when settled | |
| `qt.catalog` | `live` (default: the saved session, else signed out) · `mock` (demo catalog; never reads the Keychain; `Scripts/shoot.sh` passes it unless you give `-qt.catalog`) · a mock catalog folder path (also `$QT_MOCK_CATALOG`) | |

Builders add their own as `qt.<area>.<name>` (e.g. `qt.stage.chrome hidden`, `qt.lyrics.scrolled YES`), read with
`model.launch.string/bool/double("qt.stage.chrome")`, and list them here.

| Area | Keys |
|---|---|
| window | `qt.window.search <text>` · `qt.window.page album:<id\|title>\|artist:<id\|name>\|mood:<id>` (e.g. `mood:genre:Pop`, `mood:mood-relax`) · `qt.window.scroll <pt>` (Explore / artist / mood pages) · `qt.library.filter <text>` · `qt.library.scroll <pt>` (300 pins the compact header) · `qt.library.sort title\|album\|artist\|time\|added[:desc]` · `qt.library.select 1,3` · `qt.home.scroll <pt>` |
| player | `qt.player.upNext demo\|id,id` · `qt.player.autoplay NO` · `qt.player.shuffle YES` · `qt.player.repeat off\|all\|one` · `qt.player.adElapsed <s>` (with `qt.ad`: run the ad `<s>` s then pause; 2 = "Skip in 3", 6 = skippable) · DEBUG `qt.player.keyAppearance YES` (best-effort key-window rendering in background captures; check the shot and retake) |
| lyrics-ui | `qt.lyrics.scrolled` · `qt.lyrics.options` · `qt.lyrics.demoVersions` · `qt.lyrics.translationState same\|translating\|download\|unavailable\|onDevice\|appleIntelligence` · `qt.lyrics.lab` · `qt.lyrics.debug` |
| stage | `qt.stage.chrome hidden` · `qt.stage.queue YES` · `qt.stage.popover appearance` · `qt.stage.window YES` (detached window) · `qt.stage.reduceMotion YES` · `qt.stage.visualizerOnBattery YES` · `qt.stage.closeAfter <s>` · `qt.stage.noAd YES` (free account without the simulated pre-roll, e.g. the visualizer fallback) |
| glass | DEBUG `qt.reduceTransparency YES` (every glass primitive draws its Reduce Transparency solid) |
| desktop | `qt.desktop.miniMode compact\|art` · `qt.desktop.miniLyric` · `qt.desktop.miniHover` · `qt.desktop.lyricsUnlocked` · `qt.desktop.menuBarScroll` · `qt.desktop.lyricsSize <pt>` · `qt.settingsTab general\|playback\|lyrics\|account\|integrations\|advanced`; DEBUG: `qt.desktop.switchLanguage`, `qt.desktop.popUpMenu <index>` (1 = File, 3 = View, 4 = Controls), `qt.desktop.showShortcuts`, `qt.desktop.accountPreview signedIn\|premium\|signingIn\|expired\|signedOut` (Settings › Account without Keychain access), `qt.desktop.staleMenus YES` (General shows Relaunch), `qt.desktop.scriptProbe <path>` (runs AppleScript against the app from inside it — no Automation prompt — and writes the results as JSON) |
| lyrics-live | `qt.lyrics.unofficial all\|none\|netease,kugou,qq` (session-only Settings override) · `qt.lyrics.engine live\|mock` (default live) · `qt.lyrics.cache memory\|<path>` (fresh lookup; default Application Support/<bundle id>/Lyrics.sqlite) · `qt.lyrics.offline YES` (every source unreachable → fallback path) |
| data-live | `qt.live.open album:<id\|title>` · `artist:<id\|name>` · `playlist:<id>` (once the library has loaded) · `qt.live.state skeleton\|offline\|unavailable\|expired` (pins every live page's state) · `qt.live.signedOut YES` (signed-out screen, no Keychain read) · with it `qt.live.signIn YES` (Google sign-in window in a throwaway WebKit store; a login there is never kept) |
| stage-video | DEBUG `qt.video.debugVisibleHost YES` (orders the web engine's host window onto U270CA, alpha 1 — page diagnostics only) |
| playback | `qt.engine auto\|simulated\|web` · `qt.playback.silent` · `qt.playback.persist` · `qt.playback.nowPlaying` · `qt.playback.anonymous` · `qt.playback.readyWhen playing\|ad\|buffering\|failed\|toast` (+ `qt.playback.readyTimeout <s>`, default 120) · `qt.playback.loadDelay <s>` (slow-network look) · DEBUG: `qt.playback.statusFile <path>` (JSON status twice a second: engine, queue, Now Playing, the player page's `LOGGED_IN`/`IS_SUBSCRIBER`, main window, catalog mode) and distributed-notification commands (`QTPlaybackDebugHooks`, incl. `window:close` / `window:reopen` without activation) |

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
  **SDK stamp:** SwiftPM's default build system (swiftbuild) writes `LC_BUILD_VERSION sdk` = the deployment target
  (15.0) instead of the SDK it compiled against, and AppKit/SwiftUI choose the macOS 26+ design from the linked-on
  SDK — so the app ran in the old look on Tahoe (flush grey sidebar, flat toolbar). The script restamps the
  executable with `xcrun vtool -set-build-version macos <minos> <sdk>` before signing; check with
  `otool -l <app>/Contents/MacOS/QTubeMusic | grep -A4 LC_BUILD_VERSION` (`minos 15.0`, `sdk 27.0`). Binaries run
  straight from `swift run` keep the 15.0 stamp (old look).
- `build-app.sh` also: embeds **Sparkle.framework** in `Contents/Frameworks` (rpath `@executable_path/../Frameworks`,
  build-folder rpaths removed); copies `QTubeMusic.sdef` (`NSAppleScriptEnabled`, `OSAScriptingDefinition`);
  compiles `AppIntents.xcstrings` / `AppShortcuts.xcstrings` to `.lproj/*.strings`; extracts **App Intents metadata**
  like Xcode does (`swiftc -typecheck -emit-const-values-path` for the app module, then `appintentsmetadataprocessor`
  → `Contents/Resources/Metadata.appintents`; a warning, not a failure, if it can't); signs ad hoc inside out
  (Sparkle's XPC services, Autoupdate, Updater.app, the framework, then the app).
- `Scripts/shoot.sh <outname> [--window main|mini|desktopLyrics|menuBarPopover|settings]… [launch args]` —
  quits that variant, `open -g -n` with `-qt.screen U270CA -qt.readyFile …`, waits for the ready file, finds window
  ids with `Scripts/tools/qt-window-id.swift` (compiled to `.build/qt-tools/`, CGWindowList by pid + title; Settings
  via the ready file because its title is the localized tab name), `screencapture -l<id> -o -x` into the main
  checkout's `screenshots/<outname>.png` (+ `<outname>-<window>.png`), quits, restores the frontmost app if it
  moved. Retakes a capture that Stage Manager shrank or caught mid-animation (narrower than the window, wrong
  aspect, transparent corners, nearly empty, or not yet stable across two captures). Passes `-qt.catalog mock`
  unless the caller gives `-qt.catalog`. `QT_SETTLE` (default 1 s) waits before capturing. `QT_KEEP=1` leaves it
  running; `QT_BUILD=1` builds first. Prefix outnames with your area.
- `Scripts/shoot-region.sh` — screen-region capture on U270CA (mini player, unlocked desktop lyrics), clamped to that display (`qt-window-id --display-bounds`) so a margin never reaches the user’s screen; other
  windows on that display can show at the edges. `Scripts/tools/qt-composite.swift` composites a transparent
  window capture over system wallpapers (desktop-lyrics shots).
- `Scripts/make-app-icon.sh` (`Scripts/tools/qt-make-icon.swift`) — renders `Assets/AppIcon.icns` (macOS 15–25)
  and the Icon Composer `Assets/AppIcon.icon` that `build-app.sh` compiles with actool (`Assets.car`).
- `Scripts/now-playing.sh clients|item|info|send <cmd> <bundle id>` — the system's Now Playing state through
  MediaRemote (a dylib, `Scripts/tools/qt-nowplaying.m`, loaded into Apple-signed `/usr/bin/perl`, since macOS 15.4
  MediaRemote only answers entitled processes). `clients` lists every entry (WebKit's GPU process shows up as
  `com.apple.WebKit.GPU/<bundle id>`); `send` refuses unless the given bundle owns the active player.
- `Scripts/playback-acceptance.py [--plays 10] [--lang en-US] [--shots <prefix>] [--signed-in]` (`QT_VARIANT=…`) — M4
  acceptance in the bundled app, silent: N tracks in a row without a stall, one Now Playing entry, elapsed/artwork,
  remote commands in-process (MPRemoteCommandCenter dispatch) and through the system, CPU playing/paused; report in
  `.build/playback-acceptance.json`. `--signed-in`: the user's library with signed-in playback, plus a signed-in
  (Premium) player page, no ads, closing/reopening the main window keeps playback, and the queue survives a graceful
  relaunch (`-qt.playback.persist YES`; the variant's saved queue is cleared first). While it runs the test app is
  the system's Now Playing app.
- `swift run --scratch-path .build/<you> QTPlaybackLab --scenario basic|advance|cue|power|errors|probe|switch` — the engine
  alone, headless. `switch` (M5 acceptance): for each of `--queries "a|b|c"` (default Ed Sheeran Perfect, Adele Hello,
  Coldplay Yellow) finds the song + music video anonymously, plays muted from 0:30 and switches Song → Video → Song,
  logging asked / requested / landed position, offset and latency of every switch (pass: |offset| ≤ 0.5 s).
- DEBUG playback hooks (`QTPlaybackDebugHooks`) also take `pip` and `eval:<js>`; the status file adds `video`
  (presenting, hasFrame, pip, size, container) and `modeSwitches` (every measured Song⇄Video switch).
- `swift run --scratch-path .build/<you> QTNativeSpike bench [--signed-in] [--count N] [--clients A,B]` (also
  `clients`, `cipher`, `avplayer`) — the M5 native-engine spike, headless and muted; appends one line per bench run
  to `~/Library/Caches/com.roderickqiu.qtube.native-spike/runs.jsonl` for breakage tracking. Findings, numbers and
  the decision the user owns: `docs/native-engine-spike.md`.
- `Scripts/contact-sheet.sh <outname> [--title T] [--columns N] <img> <caption>…` — one captioned PNG in
  `screenshots/` (AppKit, offline).

## System integrations (spec §8, §10)

- **Dock menu** (`QTDockMenuBuilder`): now playing, transport (disabled with nothing loaded, like Controls), like,
  shuffle, Repeat submenu (Off / Repeat All / Repeat One), mini player, desktop lyrics.
- **Sidebar context menu** on Liked Songs and playlists: Play, Shuffle, Play Next, Copy Link (live lists load first).
- **Mini player accessibility**: the panel is one labelled element ("Mini Player", value = title, artist) with named
  actions Show Main Window, Close Mini Player, Switch Size, so the hover-only controls are reachable without a mouse.
- **Settings › Playback** effects (gapless, crossfade, EQ) are gated on the *playing engine's* capabilities
  (`player.capabilities`), not the account tier: the web engine (free and Premium today) shows them off + a note.
- **Shortcuts / App Intents** (app target): Play or Pause, Play, Pause, Next Song, Previous Song, Like Current Song
  (in-app only — nothing is written to YouTube Music), Play Playlist (Liked Songs + library playlists as an
  `AppEntity`), Get Current Song (returns "Title — Artist"); App Shortcuts phrases in en + zh-Hans. None open the app.
- **AppleScript**: `play`, `pause`, `playpause`, `next track`, `previous track`; application properties `player state`
  (stopped/playing/paused), `current track` (name, artist, album, duration, video id), `player position` (rw),
  `sound volume` (0–100, rw). `QTScripting` (Desktop/) + the app delegate's KVC properties.
- **Notifications**: General › "Notify when the song changes" (off; permission is requested only when turned on).
  Posted by `QTTrackChangeNotifier` when the song changes while the app isn't active (not for the paused launch
  track, never for ads), artwork attached, one at a time.
- **Last.fm** (Settings › Integrations, off): the app has no registered Last.fm API account yet, so the user enters
  their own API key + shared secret (https://www.last.fm/api/account/create), presses Connect… (auth.getToken →
  last.fm approval page in their browser) and Finish Connecting (auth.getSession). Shared secret and session key are
  Keychain items (service `com.roderickqiu.qtube.integrations`); only the key and user name are in defaults.
  Scrobbles follow Last.fm's rules (> 30 s; half the track or 4 min of *listening*), now-playing updates are
  optional, unsent plays wait in `Application Support/<bundle id>/Scrobbles.json` (14-day limit) and go out 50 at a
  time; error 9 (revoked session) disconnects with a toast. When the app gets its own key, ship it instead of the
  fields.
- **Discord Rich Presence** (Settings › Integrations, off): needs the user's Discord application ID; talks only to
  the local Discord client over `$TMPDIR/discord-ipc-N` (handshake, `SET_ACTIVITY` "Listening to": title, artist,
  album art by its https URL, elapsed/remaining, "Open in YouTube Music" button). Paused/stopped clears it.
- Tests use stub transports and local frames only — never real Last.fm/Discord accounts.

## Updates (Sparkle)

Sparkle 2 is linked (app target only) and embedded, but **dormant** until there is a Developer ID: Info.plist has no
`SUFeedURL` and no `SUPublicEDKey`; `SUEnableAutomaticChecks` / `SUAutomaticallyUpdate` / `SUAllowsAutomaticUpdates`
are NO; `QTUpdater` never starts the updater without a feed, and the app menu's **Check for Updates…** stays
disabled. Without an EdDSA key Sparkle would refuse unsigned updates anyway. Turning it on (user-gated): Developer ID
signing + notarization, an appcast URL in `SUFeedURL`, `SUPublicEDKey` from Sparkle's `generate_keys`, signed archives.

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
`QTCoreTests` (models, queue, lyrics, settings, catalog, localization + catalog coverage — a quote-aware scan of
every `QTLoc.tr(…)` call, plus the App Intents catalogs), `QTIntegrationsTests` (Last.fm signing/requests, scrobble
rules and queue, Discord framing — no network), `QTPlaybackTests`
(simulated engine with an injected clock — no sleeps), `QTLyricsTests` and `QTInnerTubeTests` (recorded fixtures
go in their `Fixtures/` folders, accessed with `Bundle.module.url(forResource: "Fixtures", withExtension: nil)`;
record only anonymous public responses, no user data), `QTUITests` (launch options, SF Symbols, theme, key routing,
Dock menu, `QTLiveCatalogStore` transitions and the auth restore → WebKit cookie sync with an in-memory Keychain/jar
and a stub transport).
Tests must pass offline and without the git-ignored catalog. Run: `swift test --scratch-path .build/<you>`.
