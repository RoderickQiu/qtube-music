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
| `QTPlayback` | QTCore, QTInnerTube | `QTPlaybackEngine` protocol, `QTSimulatedPlaybackEngine`, `QTQueueController` (queue + context, shuffle/repeat, autoplay continuation, persistence via `QTQueueStore`, holds a process activity while playing), `QTNowPlayingController` (sole owner of Now Playing + remote commands), `Web/QTWebPlaybackEngine` (hidden WKWebView in the non-persistent session jar `QTWebKitCookieStore.session`, `sessionDidChange()`, JS bridge, ads, playability errors, offline recovery, 144p decode, page freeze while paused; `QTWebKitTuning` keeps the hidden page scheduled), `Web/QTWebVideoOutput` (M5: the page's music video in app views, native PiP, `QTModeSwitchReport`), `Web/Audio/` (web-audio: `QTWebAudioScript` page tap + `QTWebAudioTap` = `QTWebPlaybackEngine.audio`, spectrum for the visualizer decoded from the audio the page appends to its MediaSource, pulled only while a visualizer shows — `docs/web-audio.md`), `QTPlaybackEngineSelector`; `Native/` = the native Premium engine (opt-in, option B of `docs/native-engine-spike.md`): `QTNativePlaybackEngine` (wraps a `QTWebPlaybackEngine` for videos and fallback; `prepareNext` → prefetch, gapless join, crossfade; Song⇄Video handovers; session fallback), `QTNativeAudioPlayer` + `QTNativeDeck` (AVAudioEngine: two player-node decks → mixer → 10-band EQ → main mixer; decode-ahead from memory; FFT tap only while asked), `QTNativeMemoryAudioFile` (AudioToolbox read callbacks + ExtAudioFile over in-memory AAC, never on disk), `QTNativeAudioFetcher` (resolve + ranged download into memory, retry with a re-checked player, LRU of 4 tracks), `QTNativeStreamResolver` (`resolvePremium`: WEB_REMIX + session; `QTNativeFailure` systemic/item), `QTNativePlayerScript` (vendored EJS solver in JavaScriptCore, `Resources/EJS` pinned by `Scripts/update-ejs.sh`; `QTNativePlayerCache` keeps preprocessed players per hash in Caches). Spike-only: `QTNativeAudioGraph`, `QTNativeStreamDownloader` (DEBUG), `QTNativeAVPlayerProbe` | playback (Web video parts: stage-video; Web/Audio: web-audio); Native/: native-engine |
| `QTDevSession` | QTAuth | DEBUG-only executable: import the dev session from CDP cookie JSON on stdin; read-only `status` / `summary` / `probe` / `ytcfg` (never prints cookie values) | data-live |
| `QTPlaybackLab` | QTPlayback | dev-only executable: drives the web engine live, muted and anonymous (`swift run --scratch-path .build/<you> QTPlaybackLab --scenario basic`) | playback |
| `QTNativeSpike` | QTPlayback, QTAuth | DEBUG-only executable for the M5 spike: `clients` / `bench` / `cipher` / `avplayer` — stream resolution per client, download → AVAudioEngine (muted), TTFA, CPU, gapless, crossfade, EQ, spectrum; `--signed-in` reads the shared dev session (never prints cookie values). Uses the vendored EJS solver; downloads audio into `~/Library/Caches/com.roderickqiu.qtube.native-spike/` (purged after each run) | native-spike |
| `QTLyrics` | QTCore, OpenCC (SwiftyOpenCC) | `QTLyricsResolver` (actor, `QTLyricsProviding`): parsers (LRC, YRC, QRC, KRC, TTML), QRC/KRC decryption, providers (YouTube Music, LRCLIB, AMLL; NetEase/Kugou/QQ opt-in), matcher, `QTLyricsCache` (SQLite), romanization, translation (selector, coordinator, Apple Intelligence + Translation framework engines), Chinese script (`QTChineseScript`, `QTChineseConverter`, `QTLyricsScriptConversion`); `QTMockLyricsProvider` | lyrics |
| `QTIntegrations` | QTCore | Opt-in integrations, all off by default: scrobbling (`QTScrobbleRules`, `QTListenTracker` in media time, `QTScrobbleQueue` offline queue per service, `QTScrobbleService` protocol, `QTScrobbler` actor fanning one listen out), Last.fm (`QTLastFMRequest` signing/requests, `QTLastFMClient`, `QTLastFMScrobbleService`), ListenBrainz (`QTListenBrainzRequest` payloads, `QTListenBrainzClient`, `QTRequestPacer`, `QTListenBrainzScrobbleService`), Discord Rich Presence (`QTDiscordIPC` framing, `QTDiscordActivity`, `QTDiscordPresence` socket actor), `QTIntegrationsSettings` + `QTIntegrationsStore` (defaults `qt.integrations.v1`; secrets in the Keychain via `QTKeychainSecretStore`) | desktop |
| `QTUI` | all | SwiftUI/AppKit UI, app model, theme | per folder, below |
| `QTubeMusicApp` (product `QTubeMusic`) | QTUI, Sparkle | `@main` app: `Window` (main), `Settings`, `MenuBarExtra`, `QTCommands`, app delegate (Dock menu, AppleScript application properties), `QTAppIntents.swift` (App Intents + App Shortcuts), `QTUpdater.swift` (Sparkle, dormant); `Resources/` (sdef, intent String Catalogs — excluded from SwiftPM, put in the bundle by build-app.sh) | desktop |

Spec names → types: PlaybackEngine = `QTPlaybackEngine`, QueueController = `QTQueueController`,
NowPlayingController = `QTNowPlayingController`, WebPlaybackEngine = `QTWebPlaybackEngine`.

**Two third-party dependencies, both approved: Sparkle** (only the app target links it) **and SwiftyOpenCC**
(`exact: 2.0.0-beta`, MIT; builds OpenCC, Apache-2.0, from source — 1.x links a system libopencc; `QTLyrics` links
its `OpenCC` product). Its dictionaries are the resource bundle `SwiftyOpenCC_OpenCC.bundle`, which build-app.sh
copies into `Contents/Resources` with the other SwiftPM bundles (its `Bundle.module` looks there first; a missing
bundle is a `fatalError` on first conversion). LyricsKit was dropped at integration: its QRC/KRC/YRC parsers and
decrypters are not public, so `QTLyrics` has its own (zlib and sqlite3 come from the system). Do not add any other
dependency without asking the user.

### What runs today (after integration)

Everything is wired (integration of M1 polish + M2–M4):

- **Catalog:** YouTube Music, always (data-live, M3; guest mode R7). `QTLiveCatalogStore` restores the saved session
  and loads the user's library; with no session it runs **guest mode** (`QTCatalogMode.guest`): Home, moods,
  Explore, search, album, artist and public playlist pages read anonymously, playback is anonymous (free, with ads),
  and the library places (Liked Songs, Songs, Albums, Artists — `QTLiveCatalogStore.isLibrary`) show a native
  sign-in state (`QTLiveSignInPrompt`: the place's SF Symbol, one line, Sign In). History stays the app's own local
  play history in every mode. The sidebar shows Sign In at its foot in guest mode and hides the empty Playlists
  section. Likes and "Add to Playlist" offer sign-in (`QTAccountGate`: a toast with Sign In) — never a local stand-in
  for the account's library.
  **Demo data never reaches users.** `QTMockCatalog` is a DEBUG tool (`QTBuild.allowsDemoData`): release builds never
  locate it (whatever `-qt.catalog` says), `Scripts/build-app.sh` bundles it only for `QT_CONFIG=debug`, and even a
  DEBUG launch only loads it for `-qt.catalog mock` (a YouTube Music launch starts from an empty catalog, so no demo
  track, lyric or palette can surface). `-qt.catalog mock` (the default in `Scripts/shoot.sh`) keeps the demo catalog
  and never touches the Keychain. `QTLiveCatalogStore.wantsLive(launch)` is the one decision; bootstrap also uses it
  for playback. The old "Use Demo Library" choice (`qt.data.demoLibrary`) is removed at launch and never read.
  **Mode transitions** (`QTLiveCatalogStore.authStateChanged`, the one place): signed in from guest mode (sidebar, a
  library page, Settings, or again after expiry) → pages reset and the library loads; signed out → guest mode at once
  (no relaunch; Home reloads anonymously); session expired → guest mode plus a "Signed out of YouTube Music" toast
  with Sign In (library pages and Settings › Account say so too), never every page failing on its own.
  Page failures: only connectivity errors (`QTInnerTubeError.isConnectivity`) read as offline; a cancelled load
  (account switch) returns the page to idle instead of a failure state. **Google's bot check** (a redirect to
  `www.google.com/sorry/…`, or a captcha / "unusual traffic" page) is `QTInnerTubeError.botCheck` →
  `QTLiveFailure.botCheck` ("YouTube wants to check this connection" + Sign In; Try Again when already signed in),
  never retried; in the player page it is `QTPlaybackError.botCheck` at once (no load timeout), the queue stops
  instead of skipping, and one toast offers Sign In. The app never opens or tries to solve the check.
- **Result tidying (R6, `QTInnerTube/Parsing/QTResultTidying.swift`):** every parsed shelf and search result keeps
  one card per release — same browse id or album playlist id, or same kind + primary artist + year + normalized title
  (case/width/Traditional-Simplified folded, "(Explicit)"/"(Clean)" dropped, a Latin re-title after a CJK title
  dropped: "新世界 NEW WORLD" = "新世界"; "(Deluxe)", "Live" and other edition words stay distinct). A live search also
  runs the videos-filtered search (`QTSearchResults.mergingVideos(from:)`, durations included) and "Music videos"
  shows `rankedVideos` (max 12): the searched-for artist's own videos, then other OMV/ATV, then the rest, anything
  over 15 min (compilations, concerts) last. Liked Songs / playlist headers show max(rows, YouTube Music's count)
  (`QTLiveCatalogStore.reportedTrackCounts`), minutes once Liked has finished paging.
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
  (`source: .live`) → `QTWebPlaybackEngine` for free and Premium. **Native engine (opt-in):**
  `QTNativeEngineCoordinator` (AppModel/) swaps in `QTNativePlaybackEngine` around that same web engine object when
  Settings › Playback › Native engine is on (`QTPlaybackEffectsPrefs.nativeEngine`, default off; session override
  `-qt.playback.native YES|NO`), the session is signed in and Premium, and playback uses the session (not anonymous);
  it swaps back when any of that stops (`QTQueueController.replaceEngine`, position kept). It also pushes Gapless /
  Crossfade / Equalizer into `QTNativePlaybackEngine.effects`. Songs then play natively; Video items, item-level
  failures and — after a systemic failure (403, bot check, solver, SABR-only) — everything for the rest of the
  session play in the wrapped web engine (`fallbackReason`; Settings says so). Native plays send no playback pings,
  so they don't reach the account's history (accepted by the user). Song⇄Video: Song→Video keeps the native song
  playing while the page loads muted, lines the page up with the native clock (hold or seek) and swaps; Video→Song
  starts native at the page's position, then stops the page. Callers that need the web engine (video surface, PiP,
  network hooks, debug) use `engine.webEngine`.
- **Next item:** `QTQueueController` tells the engine what plays next in order (`prepareNext`, after every queue
  edit; nil under Repeat One or when the end needs a wrap/continuation). An engine that moves on by itself (gapless
  join on the same deck, or a crossfade onto the other deck) reports the prepared item (`QTPlaybackItem.queueID`), and
  the queue advances without loading (`advanceToPrepared`). Gapless when crossfade is off or both tracks are from one
  album; otherwise crossfade starts `crossfadeSeconds` before the end. Loudness: loud tracks are turned down by
  YouTube's `loudnessDb` like its own player does.
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
- **Ads (web engine):** the bridge counts an ad as this load's once the page has left the previous item, and never
  resolves a load to an id seen while an ad presents (the player may report the ad's own id; resolving to it froze
  the app on "Ad · 0:00" when the content followed). An ad whose media has run out reads "Ad" with the buffering
  state, not "0:00"; one whose countdown doesn't move for 10 s while playing reloads the item once from the last
  content position (then fails like any stall). Covered by `Tests/QTPlaybackTests/QTBridgeAdTests.swift` (the
  bridge in JavaScriptCore against a fake player).


**Live data (data-live).** `QTLiveCatalogStore.shared` (attached in `QTAppModel.bootstrap`) owns the client and
`QTAuthController`, a `QTCatalogMode` (`mock` (DEBUG) / `restoring` / `guest` / `live`) and per-page `QTLivePhase`s.
`QTContentRouter` hands destinations to `QTLivePage` (AppModel/Live/) when `handles(_:)` says so: Home (mood
chips load that mood's feed), Liked and playlists (first page at once, continuation pages stream in), library Songs /
Albums / Artists. **Home and the library grids are one set** for demo + live (window): `QTHomeView` (live adds the
load phase and per-mood feeds; demo chips only toggle) and `QTLibraryAlbumsPage` / `QTLibraryArtistsPage`
(Library/QTLibraryGrids.swift: live = the store's library albums/artists with skeleton / failure / empty states, demo =
derived from the songs; both draw `QTHomeCard`). **Browse pages are one shared set** (window, Shell/QTBrowsePages.swift + QTSearchResultsView.swift)
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

**Signed-in requests (privacy audit).** `QTInnerTubeClient.send(…, identity:)` sends the session (cookies +
SAPISIDHASH + brand account) with `.session` (the default) and never with `.anonymous` (no cookies, no auth headers,
no brand account, only the visitor id of the signed-out `ytcfg` scrape). The client keeps **two visitor ids that are
never mixed**: the signed-out scrape's (or a signed-out answer's) goes only on requests without the session, the one
signed-in answers give only on signed-in requests (none until the first answer; dropped when the session provider
changes) — so an anonymous search can't be tied to the account through `X-Goog-Visitor-Id` / `context.client.visitorData`.
What the app sends on its own, and as whom:

| Request | When | Identity | Why |
|---|---|---|---|
| `search` (search field as you type, album/artist name → id, Song⇄Video search fallback) | user typing / automatic | **anonymous, always** (`search` / `searchContinuation` default) | YouTube Music keeps signed-in searches in the account's search history — an account change the user hasn't approved, and partial queries would land there too. Results are the public catalog either way. `identity: .session` exists for a future explicit opt-in. |
| `browse`: Home, Explore, moods, album / artist / playlist pages, **hover prefetch**, library lists | navigation, hover | session | Read-only; personalised Home and the user's library need it; browsing records nothing. |
| `next` for the **autoplay radio** (`RDAMVM<id>`) and the **counterpart** of the current + next track | playback | session | The web player's own read for what's playing (no history entry — watch history comes from the player page's playback reports); only signed-in answers carry counterparts; personalised radio. |
| `music/get_queue`, `account/account_menu`, the `ytcfg` GET (`accountContext`), the session-loss probe GET | restore / failures | session | Read-only account facts (Premium, region, name). |
| Timed lyrics (`QTInnerTubeLyricsClient`, ANDROID_MUSIC) | track change | anonymous | Follows the client's hl / gl and anonymous visitor id only. |
| Playback (the web engine's player page) | play | session (approved) | Plays are recorded in the user's YouTube Music history; `-qt.playback.anonymous YES` opts out. |

Tests: `Tests/QTInnerTubeTests/PrivacyTests.swift` (the counterpart fallback, plain searches, the visitor ids — with
the `ytcfg` scrape on and across a session change).

**Session storage.** The session lives in the Keychain and, in memory only, in WebKit:
- **One Keychain item per app.** Release builds use service `com.roderickqiu.qtube`, account
  `youtube-music-session`; a release build of a dev variant (`com.roderickqiu.qtube.dev-<v>`) uses
  `youtube-music-session.<v>` (`QTKeychainStore.releaseAccount`), so it never reads, prompts for or clears the
  installed app's session. DEBUG builds use the shared dev item below, or memory with `-qt.auth.store memory`.
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
| `Desktop/`, `Commands/`, `Settings/`, `Sources/QTubeMusicApp`, `Assets/AppIcon.icns` | desktop | mini player, desktop lyrics, menu bar, `QTDesktopCoordinator`, Dock menu, sidebar playlist context menu (`QTSidebarContextMenu`), `QTIntegrationsCoordinator` (Last.fm / Discord / notifications), `QTScripting` (AppleScript), `QTGlobalHotKeys` (global shortcuts), menus + key routing, Settings (incl. Integrations, `QTInterfaceLanguageSync`), app icon |
| `Theme/`, `Shared/`, `AppModel/` | shared | builders may **add**; don't rename, repurpose or break existing API |
| `AppModel/QTLiveCatalogStore.swift`, `AppModel/Live/` | data-live | live catalog wiring, guest sign-in / skeleton / failure states, `QTFixtureTransport` (DEBUG), live track-list pages (Home, library grids and browse pages are window's shared set) |

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
  and get their level from `QTLyricsMetrics.laneOpacity(rowOpacity:)`: `QTLyricsLaneLevel.current` (0.66, Increase
  Contrast 0.8) beside the current line (secondary), rising to `QTLyricsLaneLevel.inactive` (0.86) of a dimmed row's
  own opacity (≈ tertiary) — never lane alpha × row alpha. **One level on every surface**: panel / Stage rails, mini,
  desktop lyrics (baked into the fill so the outline + shadow stay full; R6: plus `QTLyricsMetrics.glow`, a wide soft
  dark cloud cast by the spread glyphs — invisible on dark wallpapers, shade behind the words on white pages and
  busy wallpapers, never a box — and `glyphUnderlay`, dark ink inside the glyphs under the dimmed unsung / lane
  fills so they read as grey, not see-through, on white; the overlay's vertical padding grows with the size so the
  panel edge never cuts the cloud), the Stage's single current line and the
  menu bar popover (`QTLyricsLaneLevel.current(_ contrast:)` in SwiftUI). One exception: the current line over the
  music video keeps its translation at ≥ 0.86 (legibility on bright frames, with its shadow and scrim).
- `QTLyricsOptionsButton(overArt:)` → system popover with `QTLyricsOptionsPopover()` (source + timing kind of what is
  showing, Translate to + status, one "Unofficial sources" switch — per-provider switches live in Settings › Lyrics —,
  timing stepper, "Lyrics Source" menu, one-click "Wrong lyrics? Report"). Opening it re-checks a translation that
  waited for a download / Apple Intelligence and retries an unreachable lookup.
- **Wrong lyrics (prelaunch §8).** `QTLyricsSourceMenu` (Lyrics/) is the one "Lyrics Source" menu, shown in Controls ›
  Lyrics Source and in the popover: Automatic, the versions best first ("LRCLIB · Line timing" over a plain subtitle,
  "Best match" / "Possible mismatch · 12 s longer" — no raw scores), No Lyrics for This Song, Report Wrong Lyrics.
  `QTLyricsVersionStore` holds the rows and the choice; the session persists it through the resolver:
  `pin` / `unpin` / `turnOffLyrics` (pin `"none"`: no document, versions still listed) / `reject` (the
  `rejections(video_id, version_id)` table: never fetched or offered again for that track, the next best shows at
  once; pinning it again takes the report back). Sanity checks in `QTLyricsMatchScorer.rescore` +
  `QTLyricsSanity` (QTLyrics/Matching): penalties, never rejections, that badge "Possible mismatch" — a non-Latin
  title over Latin-only lyrics, gibberish (mean per-line `NLLanguageRecognizer` confidence < 0.6), synced lyrics
  ending before 40 % of the track (dropped when every version does: long outro). Unofficial sources need a declared
  length, or synced lyrics sung past 60 % of the track (QQ's search lists none). Same text for different songs: the
  chosen text's fingerprint (first 8 normalised lines) goes into `fingerprints(hash, video_id, title)`; a text
  already chosen for another song whose title is < 0.9 alike (covers, live cuts, remasters pass) is skipped and not
  offered, and that song looks again. Offsets are per (videoId, version) in `version_offsets`; schema v1
  (`PRAGMA user_version`) migrated the old per-track `offsets` to the pinned version, else the cached automatic pick,
  else the first version shown.
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
  Intelligence" / "On-device translation" / provider) and says "Song is already in …" when it skips, or "Shown in …"
  when the lyrics were converted to the target's Chinese script (`QTLyricsTranslationStatus.convertedScript`); when the
  Apple Intelligence toggle is on but the model can't run (`modelNotReady`, language unsupported, unavailable) it adds
  the system's reason on a second line (`QTAppleIntelligence.Status.reason`, shared with Settings). Every machine
  translation (engine output, hosted session, cache reads) goes through `QTLyricsTranslationPolish` (a line the engine
  left unchanged — solfège, names — gets no translation line): trimmed, the
  sentence-final full stop dropped unless the sung line has one (`?`/`!`/ellipses kept). The Foundation Models prompt
  asks for a lyric register (plain Korean/Japanese endings, no line-final full stops); the Translation framework has
  no register option, so its Korean stays in the formal 습니다 style.
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
- Missing language model (`.needsDownload`): the options popover has the consent row ("Download {language} for offline
  translation") and the panel shows one quiet glass cue under the lyrics, "Translate to {language}"
  (`QTLyricsTranslationCue`); either asks for the system's download sheet (`requestDownload`). Floating buttons in the
  panel (this cue, "Current") sit above the window's floating player bar — the inspector column gets no safe-area
  inset from it. Traditional Chinese lyrics translate through the Simplified model when only that one is installed
  (direct sessions, macOS 26+).
- Pronunciation lane (pinyin, romaji): `QTSettings.lyricsPronunciation` (`QTLyricsPronunciation`: `automatic` = only
  when no translation line shows or is on its way, `on`, `off`), switched in the options popover ("Pronunciation",
  only for lyrics with that lane). A pronunciation lane that would wrap under a lyric that fits on one line is set
  up to 20 % smaller and slightly tighter instead (`QTLyricsRowBuilder.romanizationLayout`).
- The options popover keeps the translation status (source, engine, Apple Intelligence reason, download consent) in
  the "Translate to" row itself, not as a grouped-form footer (that left a section-sized gap). Unsynced lyrics say
  "Unsynced" in its header and disable the timing stepper.
- **Song⇄Video timing (R6, lyrics):** the song and its MV are often different cuts. `QTLyricsRenditionCoordinator`
  (Lyrics/) tells the session what plays (`setRendition`, from the engine's item + duration); a counterpart more than
  2.5 s longer or shorter gets `QTLyricsRenditionTiming` (QTLyrics): a strict lookup for its own length
  (`QTLyricsQuery.durationTolerance` 3 s — candidates without a declared length or of another cut are rejected;
  YouTube Music skipped; cached under `<counterpart id>~<seconds>s`, which also keys its own timing offset), shown
  unsynced while it runs and when nothing matches (`renditionTiming`: `.base` / `.own` / `.unsynced` /
  `.lookingUp`). When ≥ 3 shared lines agree on one shift (`shift(from:to:)`, first line included), the session's
  `switchTime(_:track:toCounterpart:)` maps positions and `QTQueueController.modeSwitchTime` uses it on Song⇄Video;
  the web engine's seamless switch lines its standby up with the old page shifted by that much
  (`modeSwitchShift`, ≥ 0.75 s counts). A first switch made before the shift was known is corrected once (within
  12 s, while playing). The scrubber shows the length of what plays.
- `QTSongVideoToggle(isVideo:hasVideo:)` — segmented Picker.
- `QTToastOverlay()`, `QTIcon` (prototype icon name → SF Symbol; test checks every symbol exists).
- `QTNowPlayingBarsView` (AppKit, tables) + `QTNowPlayingGlyph(isPlaying:pointSize:weight:tint:)` (SwiftUI wrapper;
  pass size and colour instead of `.font`/`.foregroundStyle`), `QTNowPlayingIndicator.pausedSymbolName` /
  `accessibilityLabel(isPlaying:)` (Shared/) — the one marker for the current track in tables, the Queue and Home:
  four level bars moving on a Core Animation loop while playing (still bars with Reduce Motion), a still
  `speaker.fill` while paused — never a pause glyph (beside a track it reads as "playing"). Home cards show it in
  their play badge when not hovered; hover shows the play/pause action instead.
- `QTTrack.qtNowPlayingSubtitle(separator:)` (NowPlaying/) — "Artist — Album" for the Stage / panel, artist only
  when the album repeats the title (singles, "… - Single").
- `QTTickingView(every:isRunning:)` / `QTTickingView(isRunning:restartOn:nextChange:)` + `\.qtPausesTimeDrivenViews`
  (Shared/) — the only way to redraw SwiftUI on a clock (see *Performance rules*).
- `QTAdTint.color(overArt:increasedContrast:)` (PlayerBar/) — the amber ad colour (scrubber fill + "Ad" label).
- Window plumbing: `QTWindowID` (identifiers + capture titles), `QTWindowAccessor`, `QTWindowPlacement`,
  `QTReadiness` (`hold`/`release` around anything async the first frame needs). The main window keeps the user's
  autosaved frame; `QTWindowPlacement.shouldPlaceMainWindow` places it only for `-qt.screen` / `-qt.window` launches
  or when no autosaved frame exists. Its NSWindow title is the current page (`QTWindowTitle`, hidden in the
  toolbar) — scripts find the main window through the ready file's identifier, not by title.
- **Screen guard** (`QTScreenGuard`, AppModel/QTWindowSupport.swift): a DEBUG launch that names a display
  (`QTLaunchOptions.effectiveScreenName`: `-qt.screen`, else U270CA for any launch with a `-qt.*` argument; plain
  Finder/Dock launches name none) **refuses to start** when it isn't connected — stderr + log + `-qt.readyFile` gets
  `{"error": "screenMissing", "screen", "screens", "pid"}`, exit 69 — and **quits** if the display disappears mid-run,
  instead of letting AppKit put its windows on the user's main display. `-qt.screen main|any|none` asks for no
  display. Release builds ignore `-qt.screen`. `QTWindowPlacement.screen(named:)` logs (once) when a named display is
  missing.
- `QTMainActorHop` (QTCore/Concurrency/) — **use instead of `MainActor.assumeIsolated`** in AppKit/Foundation callbacks
  (notification blocks, KVO, timers, AX getters, WebKit delegates, scripting commands): `onMainThread { }` runs the
  body synchronously on the main thread (checked), `run { }` hops when off it, `sync { }` returns a value. On macOS 27
  the runtime's executor check inside `assumeIsolated` itself crashed (EXC_BAD_ACCESS in `swift_task_isMainExecutorImpl`,
  a window notification posted on the main thread during status-item scene setup, 2026-10-19-003124).

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
  `QTCounterpartMatcher` search; read-only; current + next track — `next` carries the session, the search fallback is
  always anonymous, see *Signed-in requests*) and owns ⇧⌘P
  (`togglePictureInPicture()`, `canTogglePictureInPicture`, `isPictureInPictureActive`). `QTQueueController.preferredMode`
  carries the choice across tracks; `setMode` loads the counterpart at the current position (queue untouched).
  **Seamless switch (video-polish):** while content plays, `QTWebPlaybackEngine` prepares the counterpart in a second,
  muted standby page from about where the old page will be once it has loaded (`QTWebPlaybackEngine+ModeSwitch.swift`,
  `QTWebStandbySwitch`), holds it once buffered, lines it up with one short seek inside its buffer, plays it when the
  old page's clock gets there and crossfades the two (equal power, 0.4 s, bridge `fade`), then promotes it to the
  engine's page (`QTWebVideoOutput.engineDidSwapPage`) and closes the old one — no gap, measured drift ≤ 0.07 s,
  handover 1.3–1.9 s after the click (R5: lab anonymous; 2.4 s signed in, was 2.3–4.6 s; the Song | Video switch and the slots' placeholder change at once; the
  old rendition keeps playing until then). Paused, an ad on the standby, errors, a 12 s timeout, less than
  timeout + 10 s left in the track, offline, pause/seek mid-switch → the old in-page reload (short gap). Never for a
  **signed-in free account** (`pageAccount`, from the page's own `ytcfg`): a standby watch page can roll a pre-roll,
  which would be an ad served muted in a hidden page and, after a fallback, a second play report. The track **ending
  or the page failing mid-switch** drops the standby and restores the old item; `QTQueueController.loadCurrent`
  re-checks the engine after any load returns or is cancelled, so the queue still advances / skips (it ignores engine
  states while a load is in flight). Behaviour tests with fake pages behind `QTWebPageIO`:
  `Tests/QTPlaybackTests/ModeSwitchTests.swift`. `Configuration.seamlessModeSwitch` (default on);
  `lastSeamlessFallback` says why one fell back.
- **Live video:** `QTLiveVideoView(kind: .panel | .stage, cornerRadius:) { placeholder }` (NowPlaying/) shows the web
  engine's real video with the placeholder (artwork / MV still) on top until the first frame, then crossfades
  (0.32 s); ads, PiP and the simulated engine show the placeholder (PiP adds a quiet `pip` glyph). While Video is
  wanted but the frames haven't come (a Song⇄Video switch), `QTVideoWaitIndicator` puts a system spinner over the
  still after 0.6 s (Stage: on a glass disc), gone with the first frame or after 14 s.
  `QTVideoSlotCoordinator` gives the one video to the highest visible slot (Stage > panel); none → the page goes back
  to the hidden host. `QTWebVideoOutput` (`engine.video`): `present(in:)` / `withdraw(from:)`, `hasFrame`,
  `isPictureInPictureActive`, `setPictureInPicture(_:)`, quality per slot (`small` panel … `hd1080` Stage). The
  quality is **pinned once per load** (min = max, as the content starts: 144p hidden, the slot's otherwise); every
  later change (slot moves, Now Playing ⇄ Queue, Stage, PiP) only sets a ceiling, because pinning mid-play makes
  YouTube drop its buffer and reload the media (`emptied` → seek: ~0.35 s of silence and a frozen picture per move,
  R7). YouTube's ABR then adapts on its own (it can climb past the ceiling; hidden 1080p measured the same CPU as
  144p, 2.7 vs 3.0% — hardware decode). Lab check: `QTPlaybackLab --scenario move`. How it
  works: the WKWebView moves into the slot (one reparent, window to window; the engine resumes playback if WebKit
  pauses the page on the way back into the hidden host); the `videoSurface` script hides all page UI and draws each
  decoded frame on one canvas (WebKit's inline video layer stays blank after the view changes windows), cropping
  burned-in letterbox **and pillarbox** bars (side bars first, then top/bottom between them; soft film-gate edges
  and sprocket notches included; adopted when three probes agree, then the smallest bar seen; glides, never jumps;
  capped at a square picture — vertical videos keep part of their bars and report them as
  `QTWebVideoOutput.pictureBars`, which the Stage's lyric line keeps clear of); the page never takes clicks, focus or VoiceOver (`QTWebPlaybackView`); content insets
  are zeroed so the video runs under the title bar. Native PiP is WebKit's (`_allowsPictureInPictureMediaPlayback`).
- `QTStageVideoSurfaceProvider.shared.source` (Stage/) — a native engine can still hand the Stage its own
  `.layer(AVPlayerLayer)` / `.view(NSView)`; otherwise the Stage's Video background is `QTLiveVideoView(kind: .stage)`.
  Lyrics over the video are optional (Appearance popover › "Lyrics over video", `@AppStorage("qt.stage.videoLyrics")`).
  Line changes never overlap (`QTStageLyricLineTransition`): the old line lifts out and softens in 0.2 s, the new one
  rises in 0.12 s later; Reduce Motion fades out, then in. The panel's video tile widens towards 16:9 only as far as
  the panel's width allows (the panel never grows on Song⇄Video). WebKit's PiP shows the raw `<video>` (baked-in bars
  stay there).
- In-window Stage keeps the window's own title bar and SwiftUI toolbar (so the traffic lights stay put and the
  inspector's toolbar plumbing stays consistent): Shell drops its toolbar items while `surface == .stage`, and
  `QTStageTitlebar` (Stage/) hides every remaining toolbar item (`NSToolbarItem.isHidden`, also items SwiftUI adds
  later) and shows exactly those again on close. (Swapping in an empty `NSToolbar` made showing the panel under the
  Stage loop AppKit's constraint pass until it crashed.) Under the Stage the browsing UI is `accessibilityHidden`,
  takes no hits and is disabled (after the fade-in), so VoiceOver and Full Keyboard Access only reach the Stage.
- `QTDesktopCoordinator.shared` (Desktop/) — mini player, desktop lyrics (hidden while the Stage is up, inline or
  detached; until the user moves it, its default spot steps out of the main window's way), menu bar title, Dock
  menu, `showMainWindow()` (user-initiated only). The mini player's SwiftUI host sits in a plain container view:
  as the panel's content view, `NSHostingView` grew the window by the hidden title bar's height (72 → 104 pt, past
  the bottom of the screen). A `-qt.surface mini` launch ignores the main window becoming key until it has hidden
  it (activation during launch used to end the mini player before it was ever seen).
- **Chinese script** (QTLyrics/Language/QTChineseScript.swift). 繁體 and 简体 are one written language, so a Chinese
  target never machine-translates Chinese lyrics: `QTLyricsTranslationPolicy.applyProviderLane` (every shown
  document: resolver, session, bundled fallback, target changes) ends with `QTLyricsScriptConversion.apply`, which
  converts the lyric lines in place when the target is 简体中文 / 繁體中文 and the lyrics are in the other script. Script
  detection (`QTChineseScript.detect`, also used by `QTLyricsLanguageDetector`) counts what OpenCC would change each
  way, so Cantonese and Hokkien in Han characters are recognised too; text that reads the same in both is left alone.
  OpenCC configs are script-only (s2tw / s2hk by the Mac's region — HK and MO get Hong Kong forms — and tw2s / hk2s,
  hk2s for lyrics with Cantonese-only characters): phrase segmentation picks the right character, but no regional
  idioms (软件 ↛ 軟體), since the words must match the recording. Word timing survives: the whole line converts and is
  cut back at the original word boundaries (one character for one), else each word converts alone. Converted
  documents take the target as `language` and record `scriptConvertedFrom`; results are cached (8 most recent).
  Provider lanes in the other script (NetEase/QQ zh-Hans under a 繁體中文 target) convert the same way
  (`QTLyricsTranslationPolicy.convertedTranslations`). Comparison keys for matching still fold with
  `QTHanziConversion`, and providers always get the original spelling. If OpenCC's dictionaries can't load,
  `QTChineseConverter` falls back to ICU's character-level `Hant-Hans` / `Hans-Hant`.
- `QTLyricsTiming.nudge(model, by:)` (Lyrics/) — offset change + toast; `QTLyricsVersionStore.shared`.
- `QTLyricsSession` (AppModel/QTLyricsSessionService.swift, lyrics-live) — **the one lyrics source of truth**, one per
  app (`model.lyricsSession` = `player.lyricsSession`; `player.lyrics`/`isLoadingLyrics` forward to it). Publishes
  `phase` (idle/loading/loaded/notFound/unreachable), `document` (offset applied; translation lane only when it is in
  the current target and the song isn't already in it; a Chinese lane converted to the target's script; Chinese
  lyric lines shown in the target's script, see "Chinese script" below), `fullDocument`,
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
- `QTPlaybackCapabilities`: `.web` (web engine, every account: video, AirPlay, visualizer data) · `.premium` (native:
  adds gapless, crossfade, EQ; the native engine reports `.web` once it has fallen back) · `.free` (video, AirPlay).
  The Stage's visualizer follows `.visualizerData` of the playing engine, not the account tier.
- `QTPlaybackEngine` (`@MainActor`): `capabilities`, `state`, `stateUpdates()` (new `AsyncStream` per subscriber,
  current state first), `load(_:autoplay:)`, `play`, `pause`, `seek(to:)`, `setVolume`, `setMuted`, `skipAd`,
  `stop`, `spectrum(bandCount:)`, `prepareNext(_:)` (default no-op). `QTPlaybackState` carries `status` (idle/loading/playing/paused/ended/failed),
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
  `QTPillButtonStyle` (capsule; primary = accent fill) is its macOS 15 / Reduce Transparency fallback.
  `QTChipToggleStyle` (mood/genre chips, built on `qtGlassButton`), `QTChipFlow` (wrapping layout) — Shell/QTWindowButtonStyles.swift.
- Navigation: `QTDestination` adds `.mood(QTMoodChip)` (Explore mood/genre pages).

## Native UI rules (user requirement)

The prototype defines layout, hierarchy, copy and states; the app must look like a first-class Mac app.
- Native controls: `NavigationSplitView` sidebar (system material, source-list selection), real toolbar +
  `.searchable`, `.inspector` for the docked panel, `Table`/`NSTableView` with system headers, `Picker`
  (segmented/menu), `Toggle` (`.button` style for shuffle/repeat = filled when on), `Slider`, `Stepper`, `Menu`,
  `.popover`, grouped `Form` in Settings, `NSMenu`/`.contextMenu`, sheets/alerts.
- System semantics only: `QTTheme.Colors` wraps label/secondary/tertiary/separator/window/selection colours.
- **Accent colour (R7, replaces the R5 system-only policy).** Settings › General › Accent colour: **Song** (default)
  or **System** (`QTSettings.accentSource`, launch `-qt.accent song|system`). With Song, the playing song's artwork
  colour is the app's accent everywhere: `.qtArtworkTint(model.palette)` (`.tint` + `\.qtAccent`) sits at every
  window root — main window, hosted table headers, Stage, mini player, menu bar popover, Settings — so Play, toggles,
  sliders, the scrubber, links (See All), hearts, now-playing marks, the selected mood chip, drop highlights and the
  Liked Songs tile all follow; AppKit pieces take `QTTheme.Colors.nsAccent` (track table selection fill, now-playing
  marks and hearts; the AirPlay button's active colour). `model.palette` is nil with System (or colourless art), and
  every accent then falls back to the system accent.
  - Where the colour comes from: demo tracks carry a palette from `make-mock-catalog.py`; real tracks get one from
    `QTArtworkAccentService` (Theme/): a 32 × 32 thumbnail of the artwork through `QTArtworkPalette.extract`
    (QTCore; chroma²-weighted vote over 24 OKLCH hue bins, the winning bin and its neighbours averaged in OKLab; nil
    when under 4% of the cover is colourful — greyscale, black or white art), cached per song. Sticky: the previous
    song's colour stays until the new one is known; changes animate with `QTTheme.Motion.ui` (Reduce Motion: a short
    fade). DEBUG `-qt.accent.fromArt YES` reads demo covers too (screenshots of the extractor and the fallback).
  - Legibility: the accent is `QTArtworkPalette.tintOnDark` / `tintOnLight` — the artwork hue with clamped chroma at
    a fixed WCAG luminance (0.22 dark, 0.15 light), so it is ≥ 3:1 against the window and ≥ 3:1 (dark) / ≥ 4.5:1
    (light) under white text, for any hue (`ArtworkAccentTests`). `accentOnDark` / `accentOnLight` (lighter, OKLCH
    L .74 / .56) stay for ambient washes (window tint) and the visualizer glow. Increase Contrast: system accent.
  - What may not follow: the sidebar's selection highlight (stock `List` selection; unchecked in a key window) and
    the menu bar's system menus (drawn by AppKit in the
    system accent); controls in an inactive window go grey as usual. The Stage's own slab draws its controls white.
- **Window chrome (R4).** Sidebar: the stock `NavigationSplitView` sidebar, full height — what Apple's own apps
  (Music, Finder, System Settings) show on this macOS 27 host (references `screenshots/r4-shell-ref-*.png`); no
  custom sidebar background. Search: `.searchable(placement: .toolbarPrincipal)` puts the system field in the
  content column's toolbar (centred there; it never sits over the panel); while results show, the sidebar has no
  selection. The panel's header is toolbar items of the inspector's toolbar section (`QTPanelToolbar`, NowPlaying/:
  Now Playing | Queue, flexible spacer, Hide Panel; only while the panel is shown and not under the Stage), so the
  art-tinted backdrop runs under the title bar and there are no header rows or hard dividers. Content pages use
  `qtSoftScrollEdges()` (soft scroll-edge effect under the toolbar).
- **Track tables.** Finder-style selection (the app's accent when focused, unemphasized grey otherwise; white
  text on the accent). Type-to-select and sortable headers are the jump aids; the A–Z strip appears only for lists of more than
  60 rows sorted by title (`QTTrackTableCoordinator.wantsAlphabet`), with script-aware letters (Latin initial, pinyin
  initial for Han via ICU, "#" otherwise; cached per row set). The collection header steps down (smaller tile and
  filter, then the filter on the actions row) instead of truncating Play / Shuffle.
- **No content minimum width.** `QTContentRouter` is framed `minWidth: 0`: any fixed-width piece of a page (the
  search top result, card or row artwork, header buttons) otherwise becomes the content column's minimum, and with
  the panel open in a narrower window SwiftUI's split view re-publishes min sizes inside AppKit's update-constraints
  pass until AppKit throws ("more Update Constraints in Window passes than there are views"). Reproduced on the R3
  build (search or artist page at 1291 pt with the panel, any page at 980 pt), fixed in R4. When AppKit swallowed that
  exception in a display-cycle observer, the unwound frames included a Swift task job, so Swift's thread-local
  executor-tracking record was left pointing into a dead stack frame; the next executor check on the main thread
  (`MainActor.assumeIsolated`, or the dynamic isolation check in any closure SwiftUI calls) read garbage —
  EXC_BAD_ACCESS in `SerialExecutor._isSameExecutor` / `swift_getObjectType` (the 2026-10-19 `QTHomeCard.trackCard`
  and `QTDesktopCoordinator.observeMainWindowFrame` reports: both main-thread victims, not their own bugs; verified
  with a minimal ObjC-exception-through-`Task.immediate` repro). So: never let an ObjC exception happen in layout.
- **Liquid Glass (R3).** macOS 15 stays the minimum; macOS 26+ gets glass, macOS 15 system materials, Reduce
  Transparency solid surfaces — decided in ONE place, `Theme/QTGlass.swift`. Feature code never calls
  `glassEffect` or paints `.material` backgrounds itself:
  - `qtGlass(_ role, in: shape, tint:, interactive:)` — roles `.chrome` (floating pieces over our content: toasts,
    lyrics "Current" pill), `.bar` (the player bar: glass with a dense (0.8) window-colour wash so list text never
    ghosts through the title; in light mode it also gets a hairline + soft outside shadow so it has an edge over
    white content), `.overArt` (Stage chrome, queue drawer, ad badges, mini player art controls; dark context).
    Tint = the artwork accent at ~0.12–0.16 opacity, only over art.
  - `qtGlassButton(.primary | .secondary, iconOnly:)` — `.glassProminent` tinted with the app's accent (the page's
    one primary action: collection / search top result Play) / `.glass` (Shuffle, More, open); capsule or circle.
    `QTPillButtonStyle` (macOS 15 / Reduce Transparency) fills primary with the app's accent too.
  - `qtGlassChip(isOn:)` — mood / genre chips: untinted glass off, `.glass` with a translucent accent tint on
    (`QTChipToggleStyle`); never a solid saturated fill.
  - `qtSoftScrollEdges()` — `.scrollEdgeEffectStyle(.soft, for: .top)` on macOS 26+.
  - `QTGlassGroup { … }` — `GlassEffectContainer` for neighbouring glass shapes (Stage top bar).
  - `qtFloatingBottomBar { … }` — `safeAreaBar` on macOS 26 (scroll edge effect under the bar), `safeAreaInset`
    before; the bar sits on `QTBottomBarBackdrop` (a material that fades in from the bar's top edge to the window
    edge), so SwiftUI pages and AppKit tables are frosted behind it and no half-cut rows show in the gutters. The player bar floats over the bottom of content + inspector (10 pt inset, radius 22); the sidebar
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
    design. Count columns from the measured width instead (`QTQuickPicks`, `QTLibraryGridPage`); see *No content
    minimum width* above. Quick picks use at most 3 columns of at least `QTQuickPicks.minRowWidth` (260 pt: art,
    ~136 pt of title, heart) so titles read in every appearance and catalog.
- **Docked panel width (R6).** `QTInspectorWidthKeeper` (Shell/) keeps the inspector at the design width (384 pt) or
  the user's last divider drag (`qt.window.panelWidth` in UserDefaults; dev launches with `-qt.screen`/`-qt.window`
  always use 384 and never save). SwiftUI's `inspectorColumnWidth(ideal:)` reaches AppKit only when the split item is
  first added; every later SwiftUI update that re-sets the split items (the live library streaming in) re-added it
  without its preferred size, and the panel sat at its 320 pt minimum with the live library (384 with the demo). The
  keeper adds a width constraint at priority 262 (above the inspector's holding priority 261, never required), lifts
  it while the divider is dragged and adopts the new width on mouse-up.
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

## Performance rules (spec §9 budgets)

Budgets: idle < 1 % CPU; playing in the window or on the Blur Stage < 8 % (app + WebContent); visualizer < 15 %;
video as low as possible. Measured with `Scripts/perf-cpu.py` (table and method in `docs/perf.md`). What the
budget depends on — every one of these was a real regression:
- **No `TimelineView` for clocks.** On macOS 26+ a `TimelineView(.periodic)` / `.animation` re-checks its schedule
  every display frame, which keeps the whole window's SwiftUI graph, layout and CA commits running at 120 Hz: the
  4 Hz scrubber alone cost 10–12 % CPU. Use `QTTickingView` (`Shared/QTTickingView.swift`): `every:` for a fixed
  cadence, `nextChange:` + `restartOn:` for event-driven redraws (the current-lyric line wakes at the next word or
  line, not 20×/s). It stops while its window is hidden or fully covered (`NSWindow.occlusionState`) and while an
  ancestor sets `\.qtPausesTimeDrivenViews` (the browsing UI under the in-window Stage does).
- **No SwiftUI `.symbolEffect` that repeats** (variable colour, pulse…): SwiftUI redraws it through its display
  list every frame (~15 % for one glyph in the Queue). Use AppKit's `NSImageView.addSymbolEffect`, which Core
  Animation runs — `QTNowPlayingGlyph` is the model. `.contentTransition(.symbolEffect(.replace))` (one-shot) is fine.
- Continuous motion goes to Core Animation (`QTStageLayerImage` drift / Ken Burns / vinyl spin) or Metal, never to
  per-frame SwiftUI state. The lyrics rail is AppKit/CA with boundary timers (`QTLyricsRailView`).
- Metal views stop their display link when settled and while their window is occluded, and cover only the area
  they draw (the visualizer's view is the bottom half of the Stage, `QTStageVisualizerView.heightFraction`).
- Pre-render expensive images once per track (`QTStageImageProcessor`: blurred art, frosted cover), not per frame.
- After touching anything that moves on screen, re-run the matching `perf-cpu.py` scenario and compare.

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
| `qt.screen` | display-name substring (`U270CA`, `Built-in`), or `main` / `any` / `none`. DEBUG only: defaults to `U270CA` when any `-qt.*` argument is given, and a launch whose display isn't connected refuses to start (`QTScreenGuard`). Release builds ignore it | |
| `qt.window` | `1440x900` (default) | |
| `qt.show` | comma list: `mini`, `desktopLyrics`, `menuBarPopover`, `settings` | |
| `qt.readyFile` | path; JSON `{pid, bundleID, windows:[{identifier, number, title, frame}]}` when settled | |
| `qt.catalog` | `live` (default: the saved session, else guest mode) · `mock` (DEBUG builds only — release builds ignore it — demo catalog; never reads the Keychain; `Scripts/shoot.sh` passes it unless you give `-qt.catalog`) · a mock catalog folder path (also `$QT_MOCK_CATALOG`) | |

Builders add their own as `qt.<area>.<name>` (e.g. `qt.stage.chrome hidden`, `qt.lyrics.scrolled YES`), read with
`model.launch.string/bool/double("qt.stage.chrome")`, and list them here.

| Area | Keys |
|---|---|
| window | `qt.window.search <text>` · `qt.window.page album:<id\|title>\|artist:<id\|name>\|mood:<id>\|shelf:<id>` (e.g. `mood:genre:Pop`, `mood:mood-relax`; `shelf:` = a Home shelf's See All) · `qt.window.scroll <pt>` (Explore / artist / mood pages) · `qt.library.filter <text>` · `qt.library.scroll <pt>` (300 pins the compact header) · `qt.library.sort title\|album\|artist\|time\|added[:desc]` · `qt.library.select 1,3` · `qt.home.scroll <pt>` · `qt.home.mood <id>` (e.g. `mood-focus`: launch with that chip selected) |
| player | `qt.player.upNext demo\|id,id` · `qt.player.autoplay NO` · `qt.player.shuffle YES` · `qt.player.repeat off\|all\|one` · `qt.player.adElapsed <s>` (with `qt.ad`: run the ad `<s>` s then pause; 2 = "Skip in 3", 6 = skippable) · DEBUG `qt.player.keyAppearance YES` (best-effort key-window rendering in background captures; check the shot and retake) |
| lyrics-ui | `qt.lyrics.scrolled` · `qt.lyrics.options` · `qt.lyrics.demoVersions` · `qt.lyrics.translationState same\|translating\|download\|unavailable\|onDevice\|appleIntelligence` · `qt.lyrics.lab` · `qt.lyrics.debug` |
| stage | `qt.stage.chrome hidden` · `qt.stage.queue YES` · `qt.stage.popover appearance` · `qt.stage.window YES` (detached window) · `qt.stage.reduceMotion YES` · `qt.stage.visualizerOnBattery YES` · `qt.stage.closeAfter <s>` · `qt.stage.noAd YES` (free account without the simulated pre-roll, e.g. the visualizer fallback) |
| glass | DEBUG `qt.reduceTransparency YES` (every glass primitive draws its Reduce Transparency solid) |
| desktop | `qt.desktop.miniMode compact\|art` · `qt.desktop.miniLyric` · `qt.desktop.miniHover` · `qt.desktop.lyricsUnlocked` · `qt.desktop.menuBarScroll` · `qt.desktop.lyricsSize <pt>` · `qt.settingsTab general\|playback\|lyrics\|account\|integrations\|shortcuts\|advanced`; DEBUG: `qt.desktop.hotKeys suggested` (session-only suggested set), `qt.desktop.hotKeyTaken like,playPause` (those show "Used by another app"), `qt.desktop.registerHotKeys YES` (launches with `-qt.*` arguments never register global shortcuts otherwise), `qt.desktop.switchLanguage`, `qt.desktop.popUpMenu <index>` (1 = File, 3 = View, 4 = Controls), `qt.desktop.showShortcuts`, `qt.desktop.accountPreview signedIn\|premium\|signingIn\|expired\|signedOut` (Settings › Account without Keychain access), `qt.desktop.staleMenus YES` (General shows Relaunch), `qt.desktop.integrationsExpanded YES` (Integrations opens every "Use your own …" / custom-server disclosure), `qt.desktop.listenBrainzPreview connected\|failed` (ListenBrainz connected with a sample account and custom server, or a failed Connect; no Keychain, no network), `qt.desktop.scriptProbe <path>` (runs AppleScript against the app from inside it — no Automation prompt — and writes the results as JSON) |
| lyrics-live | `qt.lyrics.unofficial all\|none\|netease,kugou,qq` (session-only Settings override) · `qt.lyrics.engine live\|mock` (default live) · `qt.lyrics.cache memory\|<path>` (fresh lookup; default Application Support/<bundle id>/Lyrics.sqlite) · `qt.lyrics.offline YES` (every source unreachable → fallback path) |
| data-live | `qt.live.open album:<id\|title>` · `artist:<id\|name>` · `playlist:<id>` (once the library has loaded) · `qt.live.state skeleton\|offline\|unavailable\|expired\|botCheck` (pins every live page's state) · `qt.live.loadDelay <s>` (DEBUG: Home and mood feeds arrive that much later — loading and transition shots) · `qt.live.signedOut YES` (guest mode, no Keychain read) · DEBUG `qt.auth.store memory` (the session lives in memory: a guest run never reads, and a sign-out never clears, the shared dev session) · DEBUG `qt.live.fixtures YES` (YouTube Music answered offline from `Tests/QTInnerTubeTests/Fixtures`, artwork offline — guest screenshots with no network) · with `qt.live.signedOut`, `qt.live.signIn YES` (Google sign-in window in a throwaway WebKit store; a login there is never kept) |
| stage-video | DEBUG `qt.video.debugVisibleHost YES` (orders the web engine's host window onto U270CA, alpha 1 — page diagnostics only) |
| playback | `qt.engine auto\|simulated\|web` · `qt.webaudio.tap NO` (web engine without the spectrum tap: A/B CPU) · `qt.playback.silent` · `qt.playback.persist` · `qt.playback.nowPlaying` · `qt.playback.anonymous` · `qt.playback.readyWhen playing\|ad\|buffering\|failed\|toast` (+ `qt.playback.readyTimeout <s>`, default 120) · `qt.playback.loadDelay <s>` (slow-network look) · DEBUG: `qt.playback.statusFile <path>` (JSON status twice a second: engine, queue, Now Playing, the player page's `LOGGED_IN`/`IS_SUBSCRIBER`, main window, catalog mode) and distributed-notification commands (`QTPlaybackDebugHooks`, incl. `window:close` / `window:reopen` without activation) |

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
  quits that variant, `open -g -n` with `-qt.screen <display> -qt.readyFile …` (display: `$QT_SCREEN` — it must be
  connected, else the run stops —, otherwise U270CA when connected, else the built-in display: `qt_screen` in
  `Scripts/lib.sh`, `qt-window-id --default-screen`), stops at once if the app refused the launch (`qt_ready_error`),
  `QT_ACTIVATE=1` brings the app forward first (only where taking focus is allowed — Stage Manager on the built-in
  display keeps a background app's windows as thumbnails), waits for the ready file, finds window
  ids with `Scripts/tools/qt-window-id.swift` (compiled to `.build/qt-tools/`, CGWindowList by pid + title; Settings
  via the ready file because its title is the localized tab name), `screencapture -l<id> -o -x` into the main
  checkout's `screenshots/<outname>.png` (+ `<outname>-<window>.png`), quits, restores the frontmost app if it
  moved. Retakes a capture that Stage Manager shrank or caught mid-animation (narrower than the window, wrong
  aspect, transparent corners, nearly empty, or not yet stable across two captures). Passes `-qt.catalog mock`
  unless the caller gives `-qt.catalog`. Launch arguments are checked first (`qt_launch_args` in lib.sh: `-key value`
  pairs; a one-string `"-qt.a x -qt.b y"` is split; a missing value or a stray word exits 2 with a message), and an
  app that quits before writing the ready file fails the run at once (`qt_wait_ready`) instead of after
  `QT_TIMEOUT`. `QT_SETTLE` (default 1 s) waits before capturing. `QT_KEEP=1` leaves it
  running; `QT_BUILD=1` builds first. Prefix outnames with your area.
- `Scripts/shoot-region.sh` — screen-region capture on the test display (same display choice, argument checks and
  demo-catalog default as shoot.sh; mini player, unlocked desktop lyrics), clamped to that display (`qt-window-id --display-bounds`) so a margin never reaches the user’s screen; other
  windows on that display can show at the edges. `Scripts/tools/qt-composite.swift` composites a transparent
  window capture over system wallpapers (desktop-lyrics shots).
- `Scripts/make-app-icon.sh` (`Scripts/tools/qt-make-icon.swift`) — renders `Assets/AppIcon.icns` (macOS 15–25)
  and the Icon Composer `Assets/AppIcon.icon` that `build-app.sh` compiles with actool (`Assets.car`).
- `Scripts/now-playing.sh clients|item|info|send <cmd> <bundle id>` — the system's Now Playing state through
  MediaRemote (a dylib, `Scripts/tools/qt-nowplaying.m`, loaded into Apple-signed `/usr/bin/perl`, since macOS 15.4
  MediaRemote only answers entitled processes). `clients` lists every entry (WebKit's GPU process shows up as
  `com.apple.WebKit.GPU/<bundle id>`); `send` refuses unless the given bundle owns the active player.
- `Scripts/playback-acceptance.py [--plays 10] [--lang en-US] [--shots <prefix>] [--signed-in]` (`QT_VARIANT=…`) — M4
  acceptance in the bundled app (on the same display shoot.sh picks; refuses a missing `$QT_SCREEN`), silent: N tracks in a row without a stall, one Now Playing entry, elapsed/artwork,
  remote commands in-process (MPRemoteCommandCenter dispatch) and through the system, CPU playing/paused; report in
  `.build/playback-acceptance.json`. `--signed-in`: the user's library with signed-in playback, plus a signed-in
  (Premium) player page, no ads, closing/reopening the main window keeps playback, and the queue survives a graceful
  relaunch (`-qt.playback.persist YES`; the variant's saved queue is cleared first). While it runs the test app is
  the system's Now Playing app.
- `swift run --scratch-path .build/<you> QTPlaybackLab --scenario basic|advance|cue|power|errors|probe|switch|spectrum|memory` — the engine
  alone, headless. `memory` (web-audio): plays up to 6 tracks (`QT_LAB_LISTEN_SECONDS`, default 20 s each) with no
  visualizer, logging the bytes the spectrum tap keeps and the WebContent RSS, then checks a visualizer opened
  afterwards gets spectra. `spectrum` (web-audio): polls `spectrum(bandCount: 96)` at 60 fps like the visualizer — signal, motion,
  mute, seek, release — and logs WebContent + app CPU with the visualizer hidden / visible / hidden again. `switch` (M5 acceptance): for each of `--queries "a|b|c"` (default Ed Sheeran Perfect, Adele Hello,
  Coldplay Yellow) finds the song + music video anonymously, plays muted from 0:30 and switches Song → Video → Song,
  logging asked / requested / landed position, offset, latency, gap and seamless/in-page of every switch (pass:
  |offset| ≤ 0.5 s, gap < 0.05 s).
- DEBUG playback hooks (`QTPlaybackDebugHooks`) also take `pip` and `eval:<js>`; the status file adds `audio`
  (spectrum tap: status, active, frames, pulls), `video` (presenting, hasFrame, pip, size, container), `modeSwitches`
  (every measured Song⇄Video switch, with `gap` and `seamless`) and `seamlessFallback`; `media.surface` shows the
  measured `bars`, the `crop` and the visible `picture` bars.
- `swift run --scratch-path .build/<you> QTNativeSpike bench [--signed-in] [--count N] [--clients A,B]` (also
  `clients`, `cipher`, `avplayer`) — the M5 native-engine spike, headless and muted; appends one line per bench run
  to `~/Library/Caches/com.roderickqiu.qtube.native-spike/runs.jsonl` for breakage tracking. Findings, numbers and
  the decision (option B, 2026-10-19): `docs/native-engine-spike.md`.
- `QT_VARIANT=<name> Scripts/native-acceptance.py [--plays 12] [--only seek,plays,crossfade,eq,video,requeue,skips,toggle,cpu,fallback] [--web]`
  — the native engine live in the bundled app (signed-in library, `-qt.playback.native YES`, silent): N tracks in a
  row with gapless seams, seek/pause, crossfade timing, EQ moving the spectrum, Song⇄Video handovers, Next/Previous
  starts, the opt-in toggled mid-song, one Now Playing entry, CPU, and a forced solver failure falling back for the
  session. `--web` measures the same CPU with YouTube's player. DEBUG hooks for it: `native:on|off|fail-solver`,
  `effects:gapless:on|off`, `effects:crossfade:<s>`, `effects:eq:<preset>`, `spectrum`, `upnext:<id>`; the status file
  adds `native` (active, fallbackReason, loads, start/fetch seconds, seams, crossfades, handovers, itag, position,
  tapFrames), `nativeOptIn`, `nativeEligible`.
- `Scripts/update-ejs.sh [version]` — re-checks the vendored EJS solver against its release checksums, or moves the
  pin (then run `swift test --filter NativeEngine` and `QTNativeSpike cipher --signed-in`).
- `Scripts/perf-cpu.py <label> [--seconds 30] [--settle 8] [--sample] [--trace "Time Profiler"|SwiftUI] [--shot <name>]
  [--background] [--keep] [launch args]` (`QT_VARIANT=…`, `QT_SCREEN`, default the built-in display) — CPU of the
  bundled app + its WebContent process over a window (`ps` cputime), mock catalog unless given. Brings the app
  forward for the measurement (clock-driven views pause while covered) and hands focus back; warns when other
  QTube instances run (they pollute the numbers). Appends a JSON line to `.build/perf-cpu.jsonl`; `--trace` writes
  `.build/perf-<label>.trace` (Instruments traces embed the process environment — keep them out of git and delete
  them after use). One-string launch arguments (an unsplit shell variable) are split; a run where the app didn't do
  what the arguments asked (not playing with `-qt.paused NO`, another engine than `-qt.engine`) is logged with
  `"valid": false` + `"invalid": <why>` and exits 1 — ignore such rows. See `docs/perf.md`.
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
  The web engine does have visualizer data (`docs/web-audio.md`); EQ and crossfade can't be done inside its page.
- **Shortcuts / App Intents** (app target): Play or Pause, Play, Pause, Next Song, Previous Song, Like Current Song
  (in-app only — nothing is written to YouTube Music), Play Playlist (Liked Songs + library playlists as an
  `AppEntity`), Get Current Song (returns "Title — Artist"); App Shortcuts phrases in en + zh-Hans. None open the app.
  Each phrase does what it says: "Play or pause …" toggles, "Pause …" → `QTPauseIntent` (never resumes), "Resume …"
  → `QTPlayIntent` (`Tests/QTCoreTests/AppShortcutPhraseTests.swift` reads the mapping from the source).
- **Global shortcuts** (Settings › Shortcuts, `Desktop/QTGlobalHotKeys.swift`, `Settings/QTShortcutRecorder.swift`):
  Play/Pause, Next, Previous, Like/Unlike (Controls › Like's path; VoiceOver announces the result), Show/Hide
  Desktop Lyrics, Show/Hide Mini Player, Show QTube Music (hides the app when it's already in front). Carbon
  `RegisterEventHotKey` on the event dispatcher target: no Accessibility permission, the key is consumed. None is
  set by default (media keys and the Shortcuts app already work); "Use Suggested Shortcuts" fills only empty actions
  with ⌃⌥⌘ P ] [ L Y M, keys placed by character in the current layout. Stored as `QTSettings.globalHotKeys`
  (`QTHotKeyBindings`, QTCore: virtual key code + Carbon modifier mask; one combo per action). The recorder is an
  NSControl with a text field cell (system bezel and focus ring): click/Tab/VoiceOver-press records, Esc cancels, ⌫
  clears, a combo needs ⌘ or ⌃ or is an F-key (macOS 15+ stopped delivering ⌥ / ⌥⇧-only hot keys; they still
  register with noErr, checked on macOS 27); every hot key is unregistered while it records. Key names come from
  UCKeyTranslate (`QTKeyboardLayout`, refreshed on input-source changes). Inline notes, first match wins: our
  registration failed (eventHotKeyExistsErr → "Used by another app"), an enabled system shortcut
  (`CopySymbolicHotKeys`, looked up with dlsym — no longer in the SDK headers), the default of an installed
  launcher / window manager (`QTPopularHotKeys`: Raycast, Alfred, ChatGPT, 1Password, Maccy, Rectangle, Magnet),
  our own menu key equivalents (a note only). Help › Keyboard Shortcuts lists them under Global Shortcuts.
- **AppleScript**: `play`, `pause`, `playpause`, `next track`, `previous track`; application properties `player state`
  (stopped/playing/paused), `current track` (name, artist, album, duration, video id), `player position` (rw),
  `sound volume` (0–100, rw). `QTScripting` (Desktop/) + the app delegate's KVC properties.
- **Notifications**: General › "Notify when the song changes" (off; permission is requested only when turned on).
  Posted by `QTTrackChangeNotifier` when the song changes while the app isn't active (not for the paused launch
  track, never for ads), artwork attached, one at a time.
- **Settings › Integrations** is switches + Connect…: Last.fm shows "Scrobble to Last.fm  [Connect…]", ListenBrainz
  "Submit listens to ListenBrainz  [Connect]" above its token field, Discord its two switches. The app has no
  Last.fm API account or Discord application of its own yet (shipping credentials is user-gated), so the user's own go in collapsed **"Use your own API key" / "Use your own application ID"**
  disclosures (bordered fields, no "Required" prompts, the "Get an API key" / "Create a Discord application" link
  inside), which open by themselves when Connect… or the Discord switch needs them. DEBUG
  `-qt.desktop.integrationsExpanded YES` opens both (screenshots). When the app ships its own credentials, drop them.
- **What is reported** (`QTIntegrationsCoordinator.reportsPlays`): only real, audible playback of the user's library
  reaches Last.fm, Discord and notifications — never the demo library (`liveCatalog.mode == .mock` or setup source
  `.mock`), the simulated engine, or silent (scripted / test) playback. Ads never.
- **Last.fm** (off): Connect… (auth.getToken → last.fm approval page in the browser) and Finish Connecting
  (auth.getSession) with the user's API key + shared secret (https://www.last.fm/api/account/create). Shared secret
  and session key are Keychain items (service `com.roderickqiu.qtube.integrations`), read **off the main thread**
  (`QTIntegrationsStore.loadLastFMSession()`); only the key and user name are in defaults. One **listen** = (video id,
  `QTQueueController.playSerial`): Repeat One, replays and Previous-restart start a new listen (scrobble + fresh
  now-playing); the paused launch track starts one when it first plays; turning Last.fm on mid-song tracks it from
  then, off forgets it unsent. Scrobbles follow Last.fm's rules (> 30 s; half the track or 4 min of *listening*;
  ad time doesn't count), now-playing updates are optional, unsent plays wait in
  `Application Support/<bundle id>/Scrobbles.json` (14-day limit) and go out 50 at a time. Errors: 9 (revoked
  session) disconnects with a toast; only 6 / 7 (the plays themselves rejected) drop a batch; key / signature /
  suspension errors (10, 13, 26, unreadable answers) **pause** sending and keep the queue (toast "Last.fm isn’t
  accepting scrobbles…") until new credentials or a relaunch.
- **Scrobble services** (`QTScrobbleService`: `maxBatch`, `maxAge`, `nowPlaying`, `submit`, `classify(Error)` →
  temporary / rejected plays / invalid credentials / account problem). One `QTListenTracker` counts **media time**
  (wall-clock × `QTPlaybackTimeline.rate`: 2× counts double, buffering and ads nothing; Last.fm's thresholds
  unchanged) and each qualifying listen lands in the queue of every configured service, each with its own file
  (`Scrobbles.json` for Last.fm, `ListenBrainz.json`), backoff (15 s doubling to 10 min, or the server's wait) and
  paused state; now playing and sends go to both services at once. A batch refused as plays is halved until the bad
  play is alone and only that one is dropped. Old queue files load (new `QTScrobble` fields are `decodeIfPresent`).
- **ListenBrainz** (off): paste the user token (https://listenbrainz.org/settings/) → Connect validates it
  (`GET /1/validate-token`) → "name [Disconnect]", "Submit listens", "Update “Now Playing”". Token in the Keychain
  (`QTIntegrationSecret.listenBrainzToken`), read off the main thread (`loadListenBrainzSession`). Submissions:
  `single` (one queued listen), `import` (up to 1,000), `playing_now`; `additional_info` names QTube Music as player
  and client (with versions), `music.youtube.com`, `origin_url` (never for uploads) and `duration_ms`. At most one
  call per second (`QTRequestPacer`); 401 disconnects with a toast; 429 waits `X-RateLimit-Reset-In` (and a used-up
  `X-RateLimit-Remaining` holds the next call); 5xx / network back off; 400 splits the batch; other answers (403, a
  404 page from a wrong server) pause with a toast. A collapsed "Use a custom server" takes the API root of a
  ListenBrainz-compatible server (Maloja: `https://<host>/apis/listenbrainz`); it is fixed while connected. DEBUG
  `-qt.desktop.listenBrainzPreview connected|failed` shows those states without the Keychain or the network.
- **Discord Rich Presence** (off): needs the user's Discord application ID; talks only to the local Discord client
  over `$TMPDIR/discord-ipc-N` (handshake, `SET_ACTIVITY` "Listening to": title, artist, album art by its https URL,
  elapsed/remaining, "Open in YouTube Music" button). Paused/stopped clears it. Sends time out after 0.5 s
  (`SO_SNDTIMEO`), so a Discord client that stops reading can't block the actor's thread.
- **Ordering:** each integration's calls go through its own `QTSerialTaskQueue` (Desktop/QTIntegrationsCoordinator.swift),
  in the order playback produced them — never one unstructured `Task` per call (Swift doesn't order those, e.g. a
  `disconnect()` overtaking a pending `update()`).
- Tests use stub transports and local frames only — never real Last.fm/Discord accounts
  (`Tests/QTUITests/QTIntegrationsCoordinatorTests.swift`: demo, Repeat One, launch track, ads, switching on mid-song,
  `switchSource`, the serial queue, Last.fm + ListenBrainz, media time; `QTIntegrationsTests`: pause vs drop;
  `QTListenBrainzTests`).

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
rules and queue, ListenBrainz golden payloads / errors / split-on-400 / fan-out / media time, Discord framing — no network), `QTPlaybackTests`
(simulated engine with an injected clock — no sleeps), `QTLyricsTests` and `QTInnerTubeTests` (recorded fixtures
go in their `Fixtures/` folders, accessed with `Bundle.module.url(forResource: "Fixtures", withExtension: nil)`;
record only anonymous public responses, no user data), `QTUITests` (launch options, SF Symbols, theme, key routing,
Dock menu, `QTLiveCatalogStore` transitions and the auth restore → WebKit cookie sync with an in-memory Keychain/jar
and a stub transport).
Tests must pass offline and without the git-ignored catalog. Run: `swift test --scratch-path .build/<you>`.
