# Pre-launch fixes: implementation report

*Research run 2026-10-20 against QTube Music 0.1.1. I read the issue trackers of Kaset, Pear Desktop, ytmdesktop,
ytmdesktop2, YTubic and JustAnotherMusicClient (about 2,550 issues), and 28 Reddit threads on r/YoutubeMusic and
r/macapps (about 500 comments). I then checked each pain point against the code. Everything was code reading and
public sources. No requests went to YouTube or Google. Line numbers are as of commit `8ef8834`.*

> **Out of scope:** installing (notarization, Homebrew cask, auto-update). The owner has set it aside for now.

Every item below can be built. None needs a new dependency. Two need a decision from the owner (§9). In total it's
roughly **35–39 working days**. Most of the risk is in playback reliability (§3) and account writes (§1), and
those are also what users complain about most.

---

## 0. Summary

| # | Item | Why it matters (evidence) | Effort | Needs owner |
|---|---|---|---|---|
| 1 | Account writes + playlist management | Likes and playlist adds are local, but the toasts say they saved. Every Reddit launch thread praises clients that sync likes back. | 0.5 d (wording) / 9–11 d (full) | **Yes**: account-writes gate |
| 2 | Brand accounts | Kaset #20, JAMC #24, Kodama thread | in #1 (2–3 d) | with #1 |
| 3 | Playback reliability | The #1 bug class everywhere: Kaset #280/#409/#245/#294, Pear #4479/#3621/#4100, ytmdesktop2 #155/#185, YTubic #16 | 8.5 d + soak | Live soak run |
| 4 | Sign-in trust + passkeys | Kaset #291/#496, "browser or app may not be secure" (ytmdesktop #866), password-in-app distrust on Reddit (29↑, 32↑) | 2 d (+2–3 d import) | One-time login test |
| 5 | Uploads library | Asked in nearly every launch thread (Kaset, Limusic, Orchard, YTubic) | 2.5 d | Fixture capture |
| 6 | ListenBrainz | Three threads; Last.fm already ships | 2 d | – |
| 7 | Global hotkeys | ytmdesktop2 #235/#211, Kaset #52; clashes with Raycast/Spotlight in Izzy thread | 2.5–3 d | – |
| 8 | Wrong lyrics | Pear #4684 (43👍, same gibberish on every song) | 2.5 d | – |
| 9 | Playback speed | Kaset #382 (7👍) | 4–4.5 d | – |

**Suggested order:** the wording fix from §1 first, because it's the only item that's actively misleading
today and takes half a day. Then §3 (reliability), §4 step 1 (sign-in), §8 (lyrics) and §6 (ListenBrainz). Then
§1 in full once the gate is decided, followed by §5, §7 and §9.

---

## 1. Account writes and playlist management

### Today

- **The write path is built but switched off.** `QTInnerTubeClient.allowsAccountWrites`
  (`Sources/QTInnerTube/Client/QTInnerTubeClient.swift:57`) defaults to false. `send` throws `.writesDisabled`
  for anything in `writeEndpoints` (:174-177, :189). `QTLiveCatalogStore.swift:205` and `:211` set the flag back
  to false on every session change. Only `rate` (:647), `addToPlaylist` (:651, with no `dedupeOption`) and
  `removeFromPlaylist` (:658) exist. There is nothing for create, delete, rename, move, subscribe or save to library.
- **Likes are in memory only.** `QTPlayerModel.toggleLike` (`Sources/QTUI/AppModel/QTPlayerModel.swift:133`) edits
  `likedTrackIDs` and nothing else, so a like is gone after a relaunch.
  - `setLiked` (`QTLiveCatalogStore.swift:616`) overwrites the set on every `LM` page while it pages through.
  - Songs past the page cap never show as liked.
  - `onRemoteLike` (`QTPlayerModel.swift:45`) skips the gate.
- **Playlist adds last only for the session.** They go through `QTPlaylistEdits`
  (`Sources/QTUI/Library/QTTrackCollection.swift:141-175`).
- **"Save Queue as Playlist" is a stub.** `QTQueueList.swift:191` only shows a "Saved" toast.
- **The copy says things that aren't true:**
  - "Added to Liked Songs" (`QTTrackActions.swift:68`)
  - "Added “x” to y" (:92-95)
  - `QTAccountSettings.swift:98` ("Your library and likes stay in your YouTube Music account.")
  - the intent description at `QTAppIntents.swift:63`
- **`setVideoId` isn't parsed** (`QTTrack` has no field for it). Remove and reorder need it.
- **Writes would be retried.** `QTRetryPolicy` (`QTInnerTubeSupport.swift:183`) retries 429/5xx. That's unsafe
  for `playlist/create` and for adds that allow duplicates.

### Endpoints (all `POST youtubei/v1/…`; refs are ytmusicapi @ `4da34b6`)

| Action | Endpoint and body | Ref |
|---|---|---|
| Like / dislike / clear | `like/like`, `like/dislike`, `like/removelike` with `{target:{videoId}}` | `mixins/_utils.py:13`, `library.py:361` |
| Save / remove album or playlist | same, with `{target:{playlistId}}` (an album is its `OLAK…` playlist) | `library.py:395` |
| Add | `browse/edit_playlist`: `ACTION_ADD_VIDEO` + `addedVideoId`, optional `dedupeOption: DEDUPE_OPTION_SKIP`. The response returns new `setVideoId`s. | `playlists.py:437-484` |
| Remove | `ACTION_REMOVE_VIDEO` + `setVideoId` + `removedVideoId` | `playlists.py:486` |
| Create | `playlist/create` `{title, description, privacyStatus, videoIds?, sourcePlaylistId?}` | `playlists.py:255` |
| Delete | `playlist/delete` `{playlistId}` | `playlists.py:423` |
| Rename / description / privacy | `ACTION_SET_PLAYLIST_NAME` / `_DESCRIPTION` / `_PRIVACY` | `playlists.py:368` |
| Reorder | `ACTION_MOVE_VIDEO_BEFORE` `{setVideoId, movedSetVideoIdSuccessor?}` | `playlists.py:382` |
| Which playlists can I add to | `playlist/get_add_to_playlist` `{videoIds}` (to add to several, send one `edit_playlist` per playlist) | kaset `YTMusicClient.swift:1566` |
| Subscribe | `subscription/subscribe` / `unsubscribe` `{channelIds:[id]}` | `library.py:413` |

### Plan

0. **Fix the wording (0.5 d, ships even if writes stay off).**
   - Change the toasts to "Liked on this Mac" and "Added for this session".
   - Fix the Settings line and the intent description.
   - Hide "Save Queue as Playlist" or show it as unavailable.
1. **Ask once, then remember (1 d).** Add `QTSettings.accountWrites: Bool?` (nil = not asked), on the same
   pattern as `nativeEngine` (`QTSettings+Desktop.swift:43`).
   - The first like or add shows a native alert: *Save likes and playlist changes to your YouTube Music account?*
     with **Save to Account** / **Keep on This Mac**.
   - Settings › Account gets a toggle, "Sync likes and playlists to YouTube Music".
   - The setting replaces the hard `false` in `QTLiveCatalogStore`. It's stored per account (and per brand
     account).
2. **Client (1.5 d).** A `QTAccountWrites` API with every row of the table above.
   - Writes are sent with `QTRetryPolicy.none`. A non-`STATUS_SUCCEEDED` response becomes an error.
   - Add `setVideoId` to `QTTrack`, and `isEditable` / `privacy` to `QTPlaylist`.
   - Parse `likeStatus` from `next` and from row menus.
3. **Write coordinator (2 d).** A new `QTUI/AppModel/QTAccountWriter.swift`, which runs writes one at a time.
   - **Optimistic UI:** the change shows straight away. If the write fails, it's undone, with an error toast that
     has Retry.
   - **Fewer writes:** quick like toggles collapse into one write.
   - **Pending overlay:** writes in flight sit in an overlay so `setLiked` can't overwrite them.
   - **Errors:** `.sessionExpired`, `.botCheck` and `.rateLimited` each get their own toast. A bot check pauses
     all writes.
   - **Refresh:** after a write it clears the cached `LM`, playlist and library pages and reloads them.
   - **Routing:** `QTPlaylistEdits` stays as the path when writes are off. `onRemoteLike` goes through the
     coordinator.
4. **UI (2–3 d).** All in native menus and sheets:
   - New Playlist sheet (name, description, privacy) from the sidebar and from Save Queue.
   - Rename and Edit; Delete with a confirmation dialog.
   - Remove from Playlist and drag-to-reorder in playlists you own.
   - An "Add to Playlist" submenu with checkmarks.
   - Subscribe on artist pages; Save to Library on album and playlist pages.

**Tests.** Use fixtures and `FakeTransport`, as in `Tests/QTInnerTubeTests/ClientTests.swift:262`:
- request shapes, and no retry on 503
- the `setVideoId`, `likeStatus` and `accounts_list` parsers
- coordinator rollback, collapsing and the overlay
- the consent states
- the existing check that guests are still blocked (`Tests/QTUITests/QTSessionPlaybackTests.swift:128`)

The signed-in fixtures (an owned playlist, edit and create responses) need one recording run. That needs the
owner's approval, or they can be built by hand from Kaset's fixtures.

**Risks.**
- Google flagging the account. Mitigation: no live writes in tests, writes one at a time, collapsed toggles,
  stop on a bot check.
- Duplicates if a write were retried (which is why writes aren't).
- Delete can't be undone, hence the confirmation.

## 2. Brand accounts (part of #1)

**Today.** `QTAuthSession.brandAccountId` (`QTAuthSession.swift:73`) already reaches `context.user.onBehalfOfUser`
(`QTInnerTubeClient.swift:281`). The response cache is already split per account (`QTInnerTubeSupport.swift:64`).
But `QTSessionStore.setBrandAccount` (`QTSessionStore.swift:87`) is never called, and there's no account list or
picker.

**How.**
- **List accounts.** `account/accounts_list` with `{}`. Each `accountItem` gives a name, handle and photo, and
  `selectActiveIdentityEndpoint…pageIdToken.pageId` gives the 21-digit id. The response also has
  `accountSigninToken.signinUrl`. Kaset's parser shows the shape: `Parsers/AccountsListParser.swift:18-164`.
- **The catch: playback history doesn't follow `onBehalfOfUser`.** Kaset ADR-0023 found that `/player` returns
  401 with it, and that plays follow the WebView's `ytcfg.DATASYNC_ID`. So switching also has to:
  1. load `signinUrl` in the player WebView
  2. check that `DATASYNC_ID` changed, and roll back if it didn't
  3. call `setCredentialsProvider` (which clears the cache)
  4. reload the library
- **The native engine** sends only `X-Goog-AuthUser` (`QTNativeStreamResolver.swift:429`), so its plays stay on
  the main account. That's acceptable, because native plays don't reach history anyway.
- **UI:** a picker in Settings › Account and in the account menu.

**Effort:** 2–3 d, counted inside #1. **Risk:** history going to the wrong account if the check in step 2 is
skipped.

## 3. Playback reliability

Kaset's silent stops come from letting YouTube's in-page queue drive playback. QTube already avoids that:
`QTQueueController` owns the queue. What's left is keeping our queue and the engine in agreement. These are
the gaps, most likely first:

1. **Pauses the page makes on its own.** This covers "Still listening?", WebKit pausing media, and a page moved
   between windows outside the 2 s grace.
   - The engine reports `.paused` while `wantsPlayback` (`QTQueueController.swift:116`) is still true, and nothing
     reconciles the two. The page's timers then freeze after 6 s (`QTWebPlaybackEngine.swift:702`, `:715`).
   - `dismissPrompts` (`QTWebPlaybackBridgeScript.swift:372`) only runs when there's a media event. If the dialog
     appears after the pause, nothing retries.
   - We never refresh YouTube's activity stamp (`_lact`), so the prompt keeps coming back.
   - This is Pear's "automatic pause after 30 minutes" (#4100).
2. **The web page crashing goes unnoticed.** The player page has no `WKNavigationDelegate`
   (`QTWebPlaybackEngine.swift:480-517`), so a WebContent crash isn't seen.
   - When paused, `play()` ignores the command's result (`:317-325`), so pressing Play does nothing. That's
     Pear's "can't click after a while" (#3621).
   - When playing, it recovers only after the 20 s stall watchdog fires.
3. **The queue ends silently when radio fails.** `fetchContinuation` swallows errors with `try?`
   (`QTQueueController.swift:685`), so the queue just stops on the last track with no message (Kaset #294).
4. **A load can stay `.loading` forever while offline.** The load timeout only counts online seconds (`:295`).
   Meanwhile `beginActivity(.idleSystemSleepDisabled)` is held (`QTQueueController.swift:737`), so the Mac never
   idle-sleeps.
5. **No sleep/wake handling** (no `NSWorkspace` observers anywhere).
6. **The native engine has no watchdog.** `configurationChanged` uses `try? startEngine()`
   (`QTNativeAudioPlayer.swift:499`), so if restarting fails it still says `.playing` and never ends.
   - Any HTTP error, including a passing 5xx, switches native to web for the whole session
     (`QTNativeStreamResolver.swift:275`).
7. **The queue and the engine can disagree about the current item** (e.g. a stale gapless chain, `:503`). After
   that, every later `.ended` fails the guard at `:718`.
8. **Network blips are treated as bad tracks.** Network errors are skipped and count toward the limit of 3
   failures in a row (`:52`, `:597`). `QTPlaybackError.isNetwork` (`QTPlaybackEngine.swift:77`) exists but is never
   used. Three timeouts in a row mean "Playback stopped" with nothing actually wrong.

### Plan

| # | Step | Main files | Days |
|---|---|---|---|
| 1 | A chaos engine (a fault-injecting test engine) and a seeded 1,000-step random soak on `ManualClock` that checks invariants after each step (below); plus targeted tests that capture today's gaps first | `Tests/QTPlaybackTests/Support.swift`, `QueueControllerTests.swift` | 2 |
| 2 | Reconcile the listener's intent with the engine: retry an unrequested pause once, then toast; don't freeze while the user is listening; `_lact` keep-alive; retry loop for the "you there" dialog; JavaScriptCore tests | `QTQueueController`, bridge, `QTWebPlaybackEngine` | 1.5 |
| 3 | Recover from a WebContent crash (navigation delegate, reload at the same position); `play()` reloads if the command fails | `QTWebPlaybackEngine` | 0.5 |
| 4 | Network errors retry with backoff instead of skipping; after 10 min offline, pause; don't block sleep while loading | `QTQueueController` :597, :730 | 1 |
| 5 | Radio continuation: timeout, 2 retries, then a toast with Retry | `QTQueueController` :673 | 0.5 |
| 6 | Sleep/wake observers: pause on sleep, fresh page after a long sleep, check the native graph is running | `QTPlaybackServices`, both engines | 1 |
| 7 | Native progress watchdog → fall back to web; a failed restart → fall back; only session-level errors switch native off for the session | `QTNativeAudioPlayer`, `QTNativePlaybackEngine`, `QTNativeStreamResolver` | 0.5 |
| 8 | If the queue and engine disagree for 2 s, reload the queue's current track | `QTQueueController` :708 | 0.5 |
| 9 | A live soak script and one run | `Scripts/playback-acceptance.py` | 1 + run time |

**Invariants the random soak checks after each step:**
- If the user is listening and something can play next, the engine is `.playing` or `.loading` within N virtual
  seconds, or a failure was reported.
- With no load in flight, the queue's current item is the engine's item.
- No queue id appears twice.
- Now Playing matches the queue.
- The sleep assertion is released whenever nothing is playing.

**Live soak (one agent only, per the traffic budget).**
- **Setup:** `QTPlaybackLab` (anonymous, so ads are covered) or the Debug app with `-qt.playback.statusFile`.
  Never both at once.
- **Pace:** real time, 3–4 h, about 15–20 tracks an hour. Don't use `advanceMany`, which seeks to the last 3 s:
  fast skipping is exactly what trips the bot check.
- **Scenarios:**
  - an album that runs into radio
  - a 10-minute pause
  - offline → online
  - Song⇄Video
  - closing and reopening the window
  - `pmset displaysleepnow`
- **Logging:** JSONL every 5 s, plus `pmset -g assertions`, the Now Playing client count, and WebContent memory.
- **Pass:**
  - zero silent stops
  - next track playing within 10 s of each natural end (not counting ads)
  - radio continues
  - one Now Playing entry
  - no `.loading` longer than 60 s
  - sleep assertion released when paused
  - memory growth under 150 MB
- **Stop at the first bot check.**

**Effort:** about 8.5 d. **Risks:**
- The `_lact` key and dialog selectors depend on YouTube's page and will drift. JavaScriptCore tests plus the
  soak catch that.
- Resuming after an unrequested pause could fight a real pause from AirPods or Control Center. So only resume
  when the pause didn't come through our own remote commands.

## 4. Sign-in trust and passkeys

### Today

- **The sign-in sheet shows no address and no lock.** `QTSignInWindowController` puts a `WKWebView` in a sheet
  with only a Cancel bar (`Sources/QTAuth/QTSignInWindowController.swift:79-96`).
  - It loads `accounts.google.com/ServiceLogin`, and is done when it lands on `music.youtube.com` with
    SAPISID + SID-family cookies (:144-153).
  - There's no `WKUIDelegate`, so Google's "Learn more" and help links do nothing.
- **The user agent is a hard-coded Safari 18.0 on Intel** (`QTInnerTube.swift:28`). It's stale on macOS 26.
- **Storage is already good.** Each attempt uses a fresh `.nonPersistent()` store (`QTAuth.swift:129`), and only
  16 allow-listed cookies are kept (`QTAuthSession.swift:87`). They're saved as one generic-password item in the
  login keychain (`QTSecureStore.swift:43-56`, `kSecAttrAccessibleAfterFirstUnlock`). The password is never
  stored.
- **Sign-out is local only** (`QTAuth.swift:175`). The Google session isn't revoked.
- **Cookie import is `#if DEBUG` only** (`QTAuth.swift:253-272`).

### Constraints (verified from public sources)

- **Passkeys and security keys can't work in our sign-in window.** An un-entitled `WKWebView` exposes
  `PublicKeyCredential`, but macOS rejects every ceremony with `NotAllowedError` and shows no UI. Google reads
  that as a failed phone check and says "Something went wrong — check Bluetooth". That's exactly Kaset #291; the
  root cause is in Kaset PR #453. The entitlement that fixes it,
  `com.apple.developer.web-browser.public-key-credential`, is managed. It's only for real browser apps, applied
  for by an organisation, and it needs a provisioning profile. An ad-hoc app can't have it.
  **Google Advanced Protection accounts can't sign in in-app at all.**
- **"Sign in with the browser" isn't possible as an OAuth-style flow.**
  - `ASWebAuthenticationSession` only returns a callback URL. The browser's httpOnly SID cookies never reach the
    app.
  - YouTube Music has rejected TV-client OAuth since 2025-08-29 (ytmusicapi #813), and yt-dlp dropped YouTube
    OAuth in 2024.11.
- **Importing cookies from browsers mostly doesn't work:**
  - **Chrome-family:** needs the "Chrome Safe Storage" Keychain prompt, and Chrome 148+ binds Google sessions to
    the device (DBSC), so copied cookies die quickly.
  - **Safari:** needs Full Disk Access.
  - **Firefox:** works (plaintext `cookies.sqlite`, no prompt). It's best done from a private window that's
    closed afterwards, so the two copies don't fight over cookie rotation (yt-dlp's advice).
- **The Safari user agent we send matters.** It's what avoids "This browser or app may not be secure", and Google
  can change that detection at any time.

### Plan (ranked)

1. **Fix the sign-in window (2 d, low risk).**
   - **Hide WebAuthn** with a document-start, all-frames script added to the sign-in configuration only (Kaset
     ADR-0033). Google then offers password → phone prompt / SMS / TOTP instead of the Bluetooth dead end.
   - **Address strip:** a lock plus `accounts.google.com`, from `webView.url` and `hasOnlySecureContent`.
     Clicking it opens `SFCertificatePanel` with `serverTrust`. Warn if the host isn't `*.google.com` or
     `*.youtube.com`.
   - **"What we keep"** line: Google's session cookies, in your Keychain, never your password; this page is a
     private session that's deleted afterwards.
   - **"Why not my browser?"** popover: macOS won't let apps read browser sign-ins, and passkeys need an Apple
     browser entitlement this app can't get. Use password + phone, or "Try another way".
   - **Help links:** a `WKUIDelegate` that opens popups in the default browser.
   - **User agent:** built from `applicationNameForUserAgent`, using the installed Safari's version.
   - **Revoke on sign-out:** load `accounts.google.com/Logout` in the session jar, and link to
     `myaccount.google.com/device-activity`.
2. **Import a session in release builds (2–3 d, medium risk).** "Advanced › Import Session from Firefox / cookies
   file", reusing `importSession`. Add a Firefox sqlite reader and a Netscape `cookies.txt` reader, with
   private-window instructions. This is the only way in for passkey-only and Advanced Protection users.
3. **Don't do:** ASWebAuthenticationSession/OAuth, Chrome Safe Storage import, Safari Full Disk Access import, or
   applying for the entitlement. A "Sign in with Chrome" (temp profile + CDP) would need a spike first: DBSC may
   kill the session within a day.

**The owner's one-time login test** (release build, macOS 15 and 26):
- password + SMS
- password + "Tap Yes" on the phone
- a passkey account (before the fix: the Bluetooth error; after: a working password / "Try another way" path)
- a security-key second step
- TOTP
- switching brand accounts
- two Google accounts in the chooser
- quit and relaunch: no Keychain prompt
- update to a new build: note any Keychain prompt
- sign out: the session is gone from "Your devices"
- nothing written under `~/Library/WebKit` for the bundle id

**Built (2026-10-20, plan items 1–2), still to check live in that test:**
- the address strip shows the lock and `accounts.google.com`; clicking it opens the certificate sheet; a work
  account's SSO page shows the "not a Google page" warning
- Google's "Learn more" / Help links open in the default browser
- `typeof PublicKeyCredential` is `undefined` on the sign-in page and Google never offers a passkey prompt
- no "This browser or app may not be secure" with the installed-Safari user agent (macOS 15 and 26)
- sign out: the session is gone from myaccount.google.com/device-activity (Settings › Account › Your Devices…)
- Import Session from Firefox (Firefox running and quit; and when macOS blocks the profiles folder, the open panel
  route); from a cookies.txt exported from a private window; the Trash prompt afterwards; an old, signed-out
  cookies.txt is refused ("this session has ended") and nothing is kept
- a passkey-only account gets in through Import Session

## 5. Uploads library

**Today.** `MUSIC_VIDEO_TYPE_PRIVATELY_OWNED_TRACK` is already parsed (`QTParseSupport.swift:223`). Nothing else
knows about uploads. The library calls live in `QTInnerTubeClient.swift:482-508` and share
`QTInnerTubeParser.libraryItems` (`QTPageParsers.swift:316`).

**How** (ytmusicapi `mixins/uploads.py`, `parsers/uploads.py`):
- **Browse IDs:** `FEmusic_library_privately_owned_tracks` / `_releases` / `_artists`. Detail pages are
  `…_release_detail…` and `…_artist_detail…`. Route these by prefix to the existing album and artist pages.
- **Songs page:** drop the first "Shuffle all" row.
- **Rows:** take `videoId` from the menu's `queueAddEndpoint` (a new fallback in `QTItemParser.swift:84`). Album
  tracks have no artist or thumbnail.
- **Auth:** add the prefix to `authOnlyBrowseIds` (`QTInnerTubeClient.swift:170`).
- **Playback:** the web engine plays uploads through the normal watch page.
  - The native engine returns `LOGIN_REQUIRED` without the owner's cookies, then falls back per item
    (`QTNativePlaybackEngine.swift:68`).
  - Uploads have no video, no radio and no YouTube lyrics. Disable Song⇄Video and Start Radio for them.
- **UI:** an "Uploads" sidebar row after History (⌘8), using a track table with a Songs | Albums | Artists
  segmented control in the toolbar. Hide the row when the account has no uploads. v1 is read-only: uploading and
  deleting are account writes.

**Tests:** five signed-in fixtures, captured once by a single agent, plus parser tests for the shuffle row, the
menu `videoId`, and album tracks with no artist. **Effort:** 2.5 d. **Open:** does the owner's account have any
uploads to capture? Upload detail pages may use the older `musicDetailHeaderRenderer`.

## 6. ListenBrainz

**API.**
- **Submit:** `POST https://api.listenbrainz.org/1/submit-listens` with `Authorization: Token <user token>`.
  - `listen_type` is `single`, `playing_now` or `import` (up to 1,000 listens).
  - Payload: `additional_info` with `media_player`, `submission_client(_version)`, `music_service`
    (`music.youtube.com`), `origin_url` and `duration_ms`.
- **Validate:** `GET /1/validate-token`.
- **Rate limit:** 429 with `X-RateLimit-Reset-In`.
- **Threshold:** the same as Last.fm, half the track or 4 minutes, whichever is lower.

**Today.** The listen rules and tracker are already independent of Last.fm (`QTScrobbler.swift:9-62`). The
Last.fm-specific parts:
- the batch size (`QTLastFMRequest.maxBatch`, :97)
- the 14-day prune (:89)
- one client and one session key in the actor (:107-213)
- the single `scrobbleKey` in `QTIntegrationsCoordinator.swift:123-196`

**How.**
- **Service protocol:** a `QTScrobbleService` protocol with `maxBatch`, `maxAge?`, `nowPlaying`, `submit`, and
  `classify(Error)`, which returns temporary, rejected, invalid credentials, or account problem.
- **Fan-out:** one listen tracker sends each listen to every enabled service. Each has its own queue file
  (`Scrobbles.json` stays for Last.fm, plus `ListenBrainz.json`).
- **ListenBrainz errors:**
  - 401 disconnects.
  - 429, 5xx and network errors back off.
  - 400 splits the batch to find the one bad listen and drops only that.
- **`QTScrobble`:** gains optional `videoId`, `isPrivatelyOwned` and `durationMs`, decoded with
  `decodeIfPresent` so old queues still load.
- **Token storage:** `listenBrainzToken` in `QTIntegrationSecret` (`QTIntegrationsSettings.swift:165`), stored in
  the Keychain.
- **Settings › Integrations, after Last.fm:** a toggle, a token `SecureField`, "Get Token…", Connect (validates),
  "name [Disconnect]", and "Update Playing Now". Optionally a custom server URL, which covers Maloja and similar.
- **Also needed for §9:** the scrobbler counts wall-clock time (`QTScrobbler.swift:46`). Switch it to media time
  so 2× playback still scrobbles.

**Tests:** golden JSON for the three listen types, one listen landing in both queues, error classification,
split-on-400, and decoding the old queue. **Effort:** 2 d.

## 7. Global hotkeys

**Today.**
- Only app-local menu shortcuts (`QTCommands.swift:33-141`) and a local key monitor (`QTKeyRouting.swift:23`).
- Media keys already work in the background through `MPRemoteCommandCenter`.
- The App Intents (`QTAppIntents.swift`) let users bind keys through the Shortcuts app today. The README should
  say so either way.

**How.**
- **API:** Carbon `RegisterEventHotKey` + `InstallEventHandler`.
  - It needs no Accessibility permission and consumes the key press.
  - It reports `eventHotKeyExistsErr` when another app holds the combo.
  - `NSEvent` global monitors need Accessibility and can't swallow the key, so they're out.
  - The KeyboardShortcuts package would be a new dependency for about 300 lines we can write ourselves.
- **New file** `Sources/QTUI/Desktop/QTGlobalHotKeys.swift` (main actor).
- **Storage:** `QTSettings.globalHotKeys: [action: (keyCode, modifiers)]`.
- **Recorder:** an `NSViewRepresentable` control.
  - Click to record; Esc cancels; ⌫ clears.
  - A combo must include ⌘ or ⌃. macOS 15 refuses ⌥-only combos; confirm on 15 and 26.
  - Key names come from the current layout via `UCKeyTranslate`.
- **UI:** a new Settings tab, "Shortcuts", next to Integrations, with a row per action and a "Use Suggested
  Shortcuts" button. The shortcuts also appear in the Keyboard Shortcuts window (`QTCommands.swift:190`).
- **Defaults: none active.** That's the Mac convention, and media keys already work.
  - Suggested set: Play/Pause ⌃⌥⌘P, Next ⌃⌥⌘], Previous ⌃⌥⌘[, Like ⌃⌥⌘L, Desktop Lyrics ⌃⌥⌘Y, Mini Player
    ⌃⌥⌘M.
  - These avoid ⌘Space (Spotlight), ⌃Space (input source), ⌥Space (Raycast/Alfred), Rectangle's ⌃⌥ arrows and
    ⌃⌥⌘8.
- **Conflict warnings, shown inline under the field:**
  - the registration error
  - enabled system shortcuts (`CopySymbolicHotKeys`)
  - our own menu shortcuts
  - a small table of launcher and window-manager defaults

**Tests:** encoding and display of combos, the conflict classifier, and settings decoding. Registration is
checked by hand on the U270CA. **Effort:** 2.5–3 d. **Risk:** non-US keyboard layouts.

## 8. Wrong lyrics

**Today.** This is better than Pear's.
- **Matching.** Scoring is 0.4 title + 0.4 artist + 0.2 duration, minus a version-tag penalty
  (`QTLyricsMatchScorer.swift:79-118`).
  - A duration off by more than ±20 s is rejected.
  - Unofficial sources need a score of 0.80 or more.
  - `rescore` drops empty lyrics and lyrics that run past the end (:122-148).
- **Controls.** "Wrong lyrics? › Other versions" pins a choice per track (`QTLyricsCache.swift:60`). Timing offsets
  are saved per track.

**Gaps.**
- **"Report Wrong Lyrics" does nothing lasting.** It adds to an in-memory `reported` set
  (`QTLyricsSession.swift:41`, `:65`) that nothing reads, so the "matcher skips it next time" comment isn't true
  and the report is lost on relaunch.
- There's no way to turn lyrics off for one song.
- Version rows don't show the duration difference or the score.
- The offset is kept per track, so a newly pinned version inherits the old version's offset.
- Nothing catches a source that serves the same text for every song, which is the Pear #4684 pattern. Our opt-in
  NetEase, Kugou and QQ sources could do the same.

**How.**
1. **A "Lyrics Source" submenu** in the Controls menu and in the popover.
   - Rows like "LRCLIB · Line timing · +3 s · 86%", with a "Possible mismatch" badge where it applies.
   - Then Automatic, then **No Lyrics for This Song** (a `none` pin).
2. **Make reports stick:** a `rejections(video_id, version_id)` table. The resolver filters on it
   (`QTLyricsResolver.swift:272`) and immediately picks the next-best version.
3. **Sanity checks in `rescore`:**
   - **Same text for different songs:** a fingerprint of the first ~8 normalised lines, in a
     `fingerprints(hash, video_id)` table. Reject when one fingerprint is chosen for 2 or more songs whose titles
     are less than 90% alike (so covers and re-releases still pass).
   - **Language:** a penalty, never a rejection, when the script clearly doesn't match the title's, or when
     `NLLanguageRecognizer` confidence is very low (gibberish).
   - **Coverage:** a penalty when synced lyrics end before 40% of the track.
   - **Unofficial sources:** require a known duration.
4. **Offset per version:** key it by (`videoId`, version).

**Tests:** a decoy provider returning the same text for 3 songs, rejections that survive a new resolver, the
`none` pin, menu labels, and Latin gibberish on a CJK title. **Effort:** 2.5 d.

## 9. Playback speed

**How.**
- **Core.**
  - `QTQueueController.rate` / `setRate`, re-applied on engine swap (`:350`) and on each load.
  - `QTPlaybackEngine.setRate`.
  - Every engine publishes `timeline.rate = speed`. Today 1 is hard-coded in `QTWebPlaybackEngine.swift:348,675`,
    `QTNativePlaybackEngine.swift:207,481` and `QTSimulatedPlaybackEngine.swift`.
- **Web engine.**
  - A `rate(r)` command: `setPlaybackRate`, plus `video.playbackRate` with `preservesPitch`, re-applied on
    `ratechange` and reported in each sample.
  - **Forced to 1× during ads.** Sped-up ads are a known ad-skipping trick, and we shouldn't look like one.
  - The 0.5 s end window scales with the rate.
  - The mode-switch line-up math divides by the rate (`QTNativePlaybackEngine.swift:404`, `:435`).
  - The bridge is at 292 of its 300-line budget (`WebEngineTests.swift:45`), so this goes in its own script, the
    way `videoSurface` does.
- **Native engine.**
  - An `AVAudioUnitTimePitch` between the crossfade mixer and the EQ, bypassed at 1×.
  - Positions stay in source frames.
  - The transition wait (`:542`) divides by the rate.
  - Gapless seams are unaffected.
- **Now Playing.**
  - Report `rate = speed` while playing (`QTNowPlayingController.swift:38`).
  - Enable `changePlaybackRateCommand` (disabled at `:243`) with rates 0.5–2.
- **Lyrics** already follow `clock.rate` (`QTLyricsRows.swift:571`); this only needs a test.
- **Scrobbler:** media time, see §6.
- **UI and settings.**
  - Controls › Playback Speed, with 0.75 / 1 / 1.25 / 1.5 / 2.
  - Shortcuts ⌥⌘. faster, ⌥⌘, slower, ⌥⌘0 reset.
  - A "1.5×" chip in the player bar when not at 1×.
  - Strings in `QTLoc` with zh-Hans.
  - Saved globally in `QTPlaybackEffectsPrefs` (`QTSettings+Desktop.swift:40`).

**Effort:** 4–4.5 d. **Risk:** YouTube may reset the rate or limit it on `music.youtube.com`. The bridge re-asserts
it and checks against the samples.

---

## 10. Decisions for the owner

1. **Account writes (§1, §2).** Enable writes behind a first-use consent, or keep them off and ship only the
   wording fix. Either way, the wording fix should ship.
2. **Signed-in fixture capture (§1, §5).** One single-agent recording run against the owner's account: an owned
   playlist, edit/create responses, `accounts_list`, uploads. The alternative is hand-built fixtures.
3. **Live playback soak (§3).** One 3–4 h real-time run. It spends part of the traffic budget, and lid sleep needs
   the owner present.
4. **Session import in release builds (§4.2).** It's the only route for passkey-only accounts, but users would be
   handling session cookies themselves.
5. **The one-time login test (§4)**, using the checklist above.

None of the items needs a new dependency.
