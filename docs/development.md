# QTube Music — development

The user-facing overview is the [README](../README.md). This page is for working on the code.

QTube Music is a native macOS player for YouTube Music, built around the now-playing experience. You get the full-screen Stage,
word-synced lyrics with translation, and Song⇄Video at the same timestamp. It has Mac manners and leaves out
everything in YouTube that isn't music. The approved spec is [docs/redesign-draft.md](redesign-draft.md)
(v0.2). The clickable prototype in `design/prototype/` is the reference for layout, copy and states.

## Requirements

- macOS 15 or later. Liquid Glass and Apple Intelligence translation need macOS 26 or later and are checked at
  runtime with `#available`.
- Xcode 27 with Swift 6.4. The package uses swift-tools 6.2 and the Swift 6 language mode (strict concurrency).
- Apple silicon. Everything here was built and measured on arm64.

## Build and run

```sh
Scripts/build-app.sh                         # → .build/apps/QTube Music.app (debug, ad-hoc signed)
QT_VARIANT=mine Scripts/build-app.sh         # → .build/apps/QTube Music mine.app, bundle id com.roderickqiu.qtube.dev-mine
QT_CONFIG=release Scripts/build-app.sh       # release configuration
open -g -n ".build/apps/QTube Music.app" --args -qt.catalog mock -qt.screen main
```

- **Always run the bundled app.** `build-app.sh` embeds Sparkle, the AppleScript dictionary, the App Intents
  catalogs and their metadata. It also restamps the binary's linked-on SDK. Without that stamp, AppKit and SwiftUI
  fall back to the pre-macOS-26 look, which is what a plain `swift run` gives you.
- **Variants run side by side.** Each `QT_VARIANT` gets its own app name, bundle id and SwiftPM scratch folder
  (`.build/<variant>`).
- **The demo library comes from the main checkout.** The mock catalog (`Generated/MockCatalog/`, built by
  `Scripts/make-mock-catalog.py` from the prototype's git-ignored `data.js` and `assets/`) contains copyrighted
  covers and lyrics, so it is never committed. The scripts find it in the main checkout, including when they run
  from a worktree. Only debug builds bundle or load it (`QTBuild.allowsDemoData`); release builds never contain it.
- **Without `-qt.catalog mock` the app goes live.** It restores the saved YouTube Music session from the Keychain;
  if there isn't one, it runs in guest mode (anonymous YouTube Music; library pages ask you to sign in).

### Tests

```sh
swift build --scratch-path .build/<you>
swift test  --scratch-path .build/<you> --disable-xctest
```

- **Keep `--disable-xctest` for now.** Every suite uses Swift Testing, so the XCTest pass has nothing to run. A
  plain `swift test` still runs that pass first, and on this host (Xcode 27.1, macOS 27) the `QTUITests.xctest`
  runner hangs in it, blocked in a CFPreferences XPC call. Re-checked 2026-10-19.
- **Current result:** 658 tests in 104 suites pass (after the pre-launch merges). They need no network and none of the git-ignored data.
- **Opt-in suites** are gated by environment variables:
  - `QT_LIVE=1`: live, anonymous InnerTube, lyrics and playback.
  - `QT_RECORD=1`: re-record the InnerTube fixtures.
  - `QT_DUMP=1`: print parser output.
  - `QT_KEYCHAIN_TEST=1`: Keychain round trip.

Use a private `--scratch-path` so you never wait on another build's SwiftPM lock.

## Dev launch arguments

Launch arguments apply to one session only and are never saved. Pass them as
`open -g -n "<app>" --args -qt.<key> <value>`. The full list, including each area's own keys, is in
[docs/architecture.md › Launch arguments](architecture.md#launch-arguments).

| Key | Values |
|---|---|
| `qt.catalog` | `live` (default), `mock` (demo library, debug builds only; never reads the Keychain), or a catalog folder path |
| `qt.surface` | `window` · `stage` · `mini` |
| `qt.section` | `home` `explore` `songs` `albums` `artists` `liked` `history` `playlist:<id>` |
| `qt.stageLayout` / `qt.stageBackground` | `standard` `lyrics-only` `art-only` / `blur` `cover` `vinyl` `video` `visual` |
| `qt.theme` · `qt.lang` · `qt.account` | `auto` `light` `dark` · `auto` `en-US` `zh-CN` · `premium` `free` |
| `qt.translation` | `auto` `off` `zh-Hans` `zh-Hant` `en` `ko` `ja` `vi` `es` `fr` `de` |
| `qt.track` · `qt.time` · `qt.paused` | mock track id · seconds · bool (default `YES`, so a launch never starts playback) |
| `qt.engine` | `auto` · `simulated` · `web` (the demo library through the real web engine, anonymous and silent) |
| `qt.screen` | display-name substring, or `main` / `any` / `none`. **Debug builds only:** any `-qt.*` launch defaults to `U270CA` and refuses to start if that display is missing |
| `qt.window` · `qt.show` · `qt.readyFile` | `1440x900` · `mini,desktopLyrics,menuBarPopover,settings` · path for a JSON file written once the window has settled |

## Scripts

| Script | What it does |
|---|---|
| `Scripts/build-app.sh` | Builds, bundles and ad-hoc signs the app (`QT_VARIANT`, `QT_CONFIG`, `QT_SCRATCH`, `--print-path`). |
| `Scripts/shoot.sh <name> [--window main\|mini\|desktopLyrics\|menuBarPopover\|settings\|signIn\|signInHelp]… [args]` | Launches in the background on the test display (`$QT_SCREEN`; otherwise U270CA if connected, else the built-in display). Waits until the app is ready, captures each window into the main checkout's `screenshots/` and quits. It retakes captures that are thumbnails or caught mid-animation, and gives focus back if the app took it. Uses `-qt.catalog mock` unless you pass `-qt.catalog`. Malformed launch arguments (a key without a value, a stray word) stop it at once; a one-string `"-qt.surface stage -qt.paused YES"` is split. |
| `Scripts/shoot-region.sh` | Screen-region capture for windows that aren't plain rectangles (mini player, unlocked desktop lyrics), kept inside the test display. Same argument checks and demo-catalog default as `shoot.sh`. |
| `Scripts/contact-sheet.sh <name> [--title T] [--columns N] <img> <caption>…` | Makes one captioned PNG in `screenshots/`. |
| `Scripts/perf-cpu.py <label> [--seconds 30] [--trace …] [args]` | Measures app and WebContent CPU over a fixed window. Appends a line to `.build/perf-cpu.jsonl`; a run where the app wasn't playing or used another engine than asked is marked `"valid": false` and exits 1. Method and results are in [docs/perf.md](perf.md). |
| `Scripts/playback-acceptance.py [--plays 10] [--signed-in]` | M4 acceptance, silent: plays N tracks in a row and checks for stalls, a single Now Playing entry, remote commands, CPU and, with `--signed-in`, queue persistence and one Song → Video → Song switch. Writes `.build/playback-acceptance.json`. |
| `Scripts/now-playing.sh clients\|item\|info\|send` | Reads the system's Now Playing state through MediaRemote. |
| `Scripts/make-mock-catalog.py` · `Scripts/make-app-icon.sh` | Build the demo catalog (git-ignored) · render the app icon. |
| `swift run QTPlaybackLab --scenario …` | Runs the web engine headless, muted and anonymous. Scenarios: `basic`, `advance`, `switch`, `spectrum`, `memory`, … |
| `swift run QTNativeSpike bench\|clients\|cipher\|avplayer` | The M5 native-engine spike (debug only, muted). |

## Modules

All modules are SwiftPM targets. Ownership, frozen APIs, the privacy audit and the performance rules are in
[docs/architecture.md](architecture.md).

| Target | Role |
|---|---|
| `QTCore` | Models, queue, lyrics document, settings, mock catalog, `QTLoc` localization and every String Catalog (en and zh-Hans). |
| `QTInnerTube` | YouTube Music API client (WEB_REMIX, SAPISIDHASH, cache, retries), parsers with the music-only filter, Song⇄Video counterparts; account writes (QTInnerTubeWrites.swift: sent once, never retried). |
| `QTAuth` | Google sign-in in a throwaway WebKit store (WebAuthn hidden, address strip), session in the Keychain, non-persistent playback cookie jar, sign-out at Google, session import from Firefox / cookies.txt. |
| `QTPlayback` | Engine protocol, web engine (hidden WKWebView), video output and PiP, web-audio spectrum tap, queue controller, sole Now Playing owner. Also holds the unused native-spike code in `Native/`. |
| `QTLyrics` | Lyrics: providers (YouTube Music, LRCLIB, AMLL; opt-in NetEase, Kugou and QQ), LRC/YRC/QRC/KRC/TTML parsers, matcher, SQLite cache, translation engines. |
| `QTIntegrations` | Last.fm, ListenBrainz and Discord Rich Presence, all off by default. |
| `QTUI` | SwiftUI and AppKit: window, library tables, inspector, player bar, Stage, karaoke renderer, mini player, menu bar, desktop lyrics, Settings. |
| `QTubeMusicApp` | `@main` app, menus, App Intents, AppleScript, Sparkle (dormant). |
| `QTPlaybackLab`, `QTDevSession`, `QTNativeSpike` | Dev-only executables. |

## Status

The milestones follow the build plan. The spec's §13 groups the same work slightly differently.

| | Scope | State |
|---|---|---|
| **M1** | Native shell: Home, library tables, docked Now Playing/Queue panel, player bar, Stage (3 layouts × 5 backgrounds), mini player, menu bar, desktop lyrics, menus, Settings; en-US and zh-CN | Done. All surfaces are built and polished across review rounds R3–R5: Liquid Glass on macOS 26+, one system accent in the window (artwork colour only as wash), no content minimum width. |
| **M2** | Lyrics: providers, parsers, matcher, cache, Core Animation karaoke renderer, free scroll with "Current", offset ±0.1 s | Done. Offline tests run on recorded fixtures for all 7 test songs, and the hero track shows word-synced Vietnamese with a Chinese translation. |
| **M3** | Real library: Home, Liked, playlists, library, Explore, search, album and artist pages; sign-in | Done with the imported dev session, read-only. The in-app Google login is built but not yet tested by the owner (see below). |
| **M4** | Web engine, queue, Now Playing, ads, errors, offline recovery | Done. Latest signed-in Premium acceptance run (R5): all 20 checks passed. 10 of 10 tracks in a row, no stall and no ads; exactly one Now Playing entry with none from WebKit, elapsed drift ≤ 0.26 s; system remote commands worked; the queue survived a relaunch; page media volume 0. CPU playing: app 0.7 %, WebContent 2.4 %; paused: app 0.25 %, WebContent 0.05 %. A song that ends or fails during a Song⇄Video switch still advances or skips the queue (covered by `ModeSwitchTests`). With ads (anonymous / free pages) the countdown runs through a whole pod (skippable ones offer Skip) and hands back to the song; an ad that stops counting reloads the item once (R6, `QTBridgeAdTests`). |
| **M5** | Song⇄Video at the same position, PiP, native-engine spike | Song⇄Video and PiP are done. On Premium and signed-out pages the switch is seamless: the other version preloads on a muted standby page and crossfades in, with offset ≤ 0.07 s and a hand-over of 1.3–1.9 s in the lab (about 2.4 s signed in). Signed-in free accounts switch inside the page instead, so a hidden standby never plays an ad or reports an extra play. When the video is another cut than the song (the hero's MV is 5:39 against a 4:17 song), the lyrics are looked up again for the video's own length; without a version for that cut they show unsynced, never drifting. When both timings line up at one shift, the switch carries the position across it (R6). The native engine is a spike only and needs a decision (below). |
| **M6** | Lyric translation (Translation framework and Apple Intelligence), Last.fm, Discord, Sparkle, App Intents, AppleScript | Built. On-device translation is shown in `r4-acceptance-translate-{en,ko}`. A missing language model shows a quiet "Translate to English" cue under the lyrics; clicking it opens the system's download sheet. Chinese→English (Simplified) and English were downloaded on this Mac in R6 (`r6-lyrics-zh-translated`); Traditional lyrics reuse the Simplified model. Pinyin shows only without a translation line unless Pronunciation is switched on in the lyrics options. The Apple Intelligence path has not run on this Mac (below). Last.fm and Discord work only with the user's own credentials. Sparkle is linked but dormant. |

**CPU** (spec §9 budgets; `docs/perf.md`, after the R6 integration, 30 s each, debug build; the video row is from R4):

| Scenario | App | WebContent | Budget |
|---|---:|---:|---|
| Idle (window, paused) | 0.9 % | – | < 1 % |
| Window, panel on Queue (simulated engine, now-playing bars) | 1.9 % | – | < 8 % |
| Web engine, window | 2.4 % | 1.5 % | < 8 % |
| Web engine, Blur Stage | 1.9 % | 2.0 % | < 8 % |
| Web engine, Visualizer Stage (real spectrum) | 7.7 % | 4.8 % | < 15 % |
| Web engine, Video Stage (real video, R4) | 6.7 % | 11.0 % | as low as possible |

## Decisions waiting for the owner

None of these has been done. Each one needs the owner's yes.

1. **Native playback engine: decided (option B).** The native Premium engine ships as an opt-in Experimental
   setting with automatic fallback to the web engine; yt-dlp's EJS solver is vendored
   ([native-engine-spike.md](native-engine-spike.md)).
2. **EQ on the web engine.** The only route is a Core Audio process tap on WebContent. That triggers the system's
   **System Audio Recording** permission prompt and adds output latency
   ([docs/web-audio.md](web-audio.md) §3). Not built. Crossfade and gapless stay native-only.
3. **App-owned Last.fm and Discord credentials.** Today users paste their own API key or Discord application ID
   into Settings › Integrations. Shipping the app's own credentials would remove that step.
4. **Optional signed-in search.** Searches are always anonymous because signed-in searches land in the account's
   search history. `identity: .session` is ready if you want an explicit opt-in.
5. **Apple Intelligence on this Mac.** `SystemLanguageModel` reports `modelNotReady` (checked 2026-10-19). Apple
   gives only that one reason; here the Mac's language is English (Hong Kong) and Siri's is English (US), and Apple
   keeps the model unavailable while they differ. To try the Foundation Models path (it asks for a lyric register:
   plain Korean/Japanese endings, no line-final full stops), set both to the same language in System Settings ›
   Apple Intelligence & Siri and General › Language & Region. Until then, translation uses the Translation framework,
   and the lyrics options show "Apple Intelligence model isn’t ready" under "On-device translation".
6. **Test the in-app Google login once.** Dev builds use the session imported from the browser profile. The normal
   Settings › Account › Sign In flow, which logs in through a throwaway store and saves the session to the
   Keychain, needs one real run by the owner.
7. **Account writes: decided (on, with a Sync switch).** Signed in, likes, playlist management, subscriptions,
   saved albums and brand-account switching change the account by default; Settings › Account › Sync off keeps
   them on this Mac. Still open: one signed-in run against a real account. Every write path is tested only against
   hand-built fixtures (shapes from ytmusicapi / Kaset), and the brand switch's `DATASYNC_ID` check against a fake
   switcher.
8. **Developer ID, notarization and a Sparkle feed.** Builds are ad-hoc signed, and Sparkle has no `SUFeedURL` or
   EdDSA key, so Check for Updates… is disabled. A Developer ID / Team ID build would also give dev builds a
   stable Keychain partition.

## Licenses and attribution

QTube Music is licensed under the Mozilla Public License 2.0 ([LICENSE](../LICENSE)). Third-party code, its
licences and the projects that informed the code are listed in [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).
No third-party content is in the repo: covers, MV stills, lyrics and the generated demo catalog stay git-ignored;
the lyrics test fixtures hold short excerpts only (at most 8 lines per song, see
`Tests/QTLyricsTests/Fixtures/README.md`).

## Releasing

`Scripts/release.sh <version>` builds, checks and packages a release locally (dry run by default) and publishes it
with `--publish`. See the comments at the top of the script and [CHANGELOG.md](../CHANGELOG.md).

## Website (qtube.r-q.name)

`site/` is a static one-page site (no build) laid out like the app's full-screen player. It's on Vercel as the
project `qtube` (team roderick-qius-projects) with **Root Directory `site`**, linked at the **repo root**
(`.vercel/` at the root, git-ignored).

- Pushes to `main` deploy through the Vercel GitHub integration (every push; the static site builds in seconds). No
  `ignoreCommand`: Vercel's checkout may have no parent commit, so `git diff HEAD^` exits with an error and fails
  the deployment (happened 2026-10-19).
- A manual deploy is `vercel deploy --prod` **from the repo root**. Never deploy from `site/` (the root directory
  would resolve to `site/site` and fail), and never clear the Root Directory setting (the whole repo would be served
  and every page 404s). The root `.vercelignore` uploads only `site/`.
- `/download` redirects to `releases/latest/download/QTube-Music.dmg`; `Scripts/release.sh` uploads that unversioned
  copy with every release, so the site never names a version.
- DNS: `qtube` CNAME on Cloudflare (DNS only), value from `vercel domains inspect qtube.r-q.name`.
