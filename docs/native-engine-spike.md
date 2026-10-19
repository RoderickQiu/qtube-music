# Native playback engine: M5 spike

*Spike run 2026-10-19 on macOS 27 (arm64), US connection, against the user's Premium account (shared dev session,
read-only) and anonymously. Code: `Sources/QTPlayback/Native/` and `Sources/QTNativeSpike/`.*

> **Decision (2026-10-19): option B.** The user chose a native engine for Premium as an opt-in "Experimental"
> setting, off by default, with automatic fallback to the web engine. They accepted the ToS risk, the monthly
> upkeep, and that native plays don't reach their YouTube history (no faked playback pings). Vendoring the EJS
> solver came with that choice. It is built: see **§8 Build-out** at the end. Sections 1–7 are the spike as it was.

The spike shows a native engine is technically easy for Premium and plays well: 23/23
tracks, about 0.66 s to first audio, sample-exact gapless playback, crossfade, a 10-band EQ and FFT data at about
1% CPU. The costs are not technical. It breaks YouTube's Terms of Service, and keeping it working is a monthly
job, on YouTube's schedule. Anonymous native playback is not viable (3/23 tracks). Options and a recommendation are
in §6.

---

## 1. What was built

| Piece | File | What it does |
|---|---|---|
| Client table | `Native/QTNativeStreamResolver.swift` → `QTNativeStreamClient` | InnerTube client identities (WEB_REMIX, TVHTML5 "Samsung", TVHTML5_SIMPLY, VISIONOS, IOS, ANDROID, ANDROID_VR), with versions and user agents as listed in yt-dlp's public client table (2026.08 release). |
| Resolver | same → `QTNativeStreamResolver` (actor) | Sends `POST /youtubei/v1/player` with a chosen client, plus `signatureTimestamp` and `visitorData` where the client needs them. For WEB_REMIX/TV it sends the signed-in session (cookie header + SAPISIDHASH). It parses `adaptiveFormats`, picks the best AVFoundation-playable audio and tries the clients in order. |
| Cipher | `Native/QTNativePlayerScript.swift` | Fetches the current player (`/s/player/<hash>/…/base.js`, ~2.9 MB) and reads `signatureTimestamp`. It solves the `sig` and `n` challenges by running **yt-dlp's EJS solver inside JavaScriptCore** (built into macOS, so no extra binary). |
| Audio | `Native/QTNativeAudioGraph.swift` | `QTNativeStreamDownloader` fetches media in range requests of 10 MB or less. `QTNativeAudioGraph` chains two `AVAudioPlayerNode`s → crossfade mixer → `AVAudioUnitEQ` (10 bands) → main mixer, **output volume 0**. A tap on the EQ feeds a vDSP FFT to produce spectrum bands. There is also an offline seam renderer and `QTNativeAVPlayerProbe`, which tests the `AVQueuePlayer` progressive path. |
| Harness | `Sources/QTNativeSpike/main.swift` | DEBUG-only CLI with `clients`, `bench`, `cipher` and `avplayer`. Each bench run appends one line to `~/Library/Caches/com.roderickqiu.qtube.native-spike/runs.jsonl` for breakage tracking. |
| Tests | `Tests/QTPlaybackTests/NativeSpikeTests.swift` | Offline tests: response parsing, format choice, cipher parsing, client table, spectrum bands, and that the engine stays unavailable. |

Reproduce (all muted, no windows, nothing activates):

```sh
swift run --scratch-path .build/<you> QTNativeSpike bench --signed-in   # Premium, 23 tracks
swift run --scratch-path .build/<you> QTNativeSpike bench               # anonymous
swift run --scratch-path .build/<you> QTNativeSpike cipher --signed-in  # player hash, sts, solve timings
swift run --scratch-path .build/<you> QTNativeSpike avplayer --signed-in --count 4
swift run --scratch-path .build/<you> QTNativeSpike clients --count 3   # client × track matrix
```

Hygiene: cookie values are never printed. Only the `player` endpoint and googlevideo media are requested. No
playback-tracking pings are sent, so nothing reaches the account's history. Downloaded audio is deleted at the end
of every bench run. The EJS solver is **not vendored**: the spike downloads the pinned release (0.8.0, Unlicense)
into the Caches folder.

## 2. How stream resolution works now (Oct 2026)

- **Formats.** `streamingData.adaptiveFormats` has audio-only renditions:
  - AAC-LC in fragmented MP4: itag 140 (~128 kbps) and, **for Premium only, itag 141 (~256 kbps)**.
  - HE-AAC: itag 139.
  - Opus in WebM: itags 249, 250 and 251, and **Premium 774 (~256 kbps)**.
- **Two kinds of URL.**
  - Some clients return plain `url`s.
  - Web and TV clients return `signatureCipher`: a scrambled signature `s`, plus an `n` parameter. Both must be
    transformed by functions buried in the current player script. Since 2025 that script is control-flow-flattened,
    so regex extraction (the old yt-dlp, NewPipe and YouTube.js approach) no longer works. yt-dlp now parses the
    player into an AST and runs it in a real JS runtime ("EJS"). We did the same in JavaScriptCore, and it solved
    every challenge.
- **PO tokens.** googlevideo now refuses media requests (HTTP 403) unless they carry a Proof-of-Origin token. The
  token is minted by BotGuard on web, or by device attestation on mobile. yt-dlp's client table marks web and
  web_music GVS tokens as `not_required_for_premium`. Our measurements agree: Premium sessions download fine without
  one, and anonymous sessions get 403 on nearly every track.
- **SABR.** Most responses also carry `serverAbrStreamingUrl`, YouTube's own streaming protocol (UMP).
  - The WEB client has already gone SABR-only: no URLs at all.
  - With current client versions, IOS and ANDROID were SABR-only in this run.
  - WEB_REMIX still returns classic URLs. When it goes SABR-only too, a native engine needs a SABR/UMP
    implementation, which is a large, undocumented protocol.
- **Bot checks.** VISIONOS and ANDROID_VR answered "Sign in to confirm you're not a bot" for most tracks from this
  connection. ANDROID_VR did so within about 10 minutes of first working.

### Per-client results today

| Client | Anonymous | Premium session |
|---|---|---|
| WEB_REMIX (music.youtube.com) | ciphered URLs; media **403** (needs PO token) | ciphered URLs incl. **141 + 774**; media downloads; **23/23** |
| TVHTML5 (Samsung profile, 5.20260707) | ciphered; 2/23 downloadable, rest 403 | "page needs to be reloaded" (unplayable) |
| TVHTML5_SIMPLY | ciphered; media 403 | doesn't accept cookies (HTTP 400) |
| VISIONOS | 1/23 ok, rest bot check | doesn't take cookies |
| IOS / ANDROID (current versions) | SABR only (no URLs) | don't take cookies |
| ANDROID_VR | bot check | doesn't take cookies |
| WEB | SABR only | (not tried) |

## 3. Numbers

### Success rate (23 tracks: the prototype's 12 CJK, Vietnamese and English tracks, plus 11 widely available music videos)

| Run | Result |
|---|---|
| Premium, WEB_REMIX first | **23/23**, twice. All 23 were served by WEB_REMIX. One earlier run counted 22/23 because a track opens with 9 s of silence and the success check waited for sound; the check now waits for rendered frames. |
| Anonymous, best client chain (VISIONOS → TV → IOS → ANDROID → VR → TV_SIMPLY → WEB_REMIX) | **3/23** |
| Anonymous, first run with older client versions | 1/23 |

Premium formats served: AAC 256 (141) on 15 tracks and AAC 128 (140) on 8, where YouTube offers no 141.

### Time to first audio

Measured from the start of the request to the first frame the player node renders. The track is downloaded in full
first: a complete 128–256 kbps file is 3–14 MB.

| | Median | p90 | Max |
|---|---|---|---|
| Premium, warm (player script and solver cached) | **661 ms** | 1036 ms | 1290 ms |
| Premium, cold first track (player fetch ~0.25 s + solver preprocessing ~1.3–2.2 s) | – | – | 3901 ms |
| Parts (warm): `player` request | 166 ms | | |
| Parts (warm): download | 468 ms | | |
| Parts (warm): `AVAudioFile` open | 1 ms | | |
| `AVQueuePlayer` progressive HTTP (no download step, `player` request not included) | 1088 ms | | |

Two conclusions:

- Downloading first, then playing through `AVAudioEngine`, is **faster** than `AVPlayer`'s progressive start.
- A shipping engine would cache the preprocessed player per hash on disk, so the cold path happens about once per
  player release.

### Solver

| Step | Time |
|---|---|
| First solve per player (AST preprocessing in JavaScriptCore) | 1.3–2.2 s, on the calling thread |
| Every solve after that | 5–70 ms |
| Player `0229cd64` (sts 20739): 2.9 MB fetch | 220–285 ms |

### CPU

Process user + system time over 10 s, where one core = 100%.

| Engine and state | CPU |
|---|---|
| Native, idle | 0.0–0.6% |
| Native, playing AAC 256 + 10-band EQ + FFT tap + spectrum polled at 10 Hz | **0.9–1.2%** |
| Native, during a 4 s crossfade (two decoders) | 1.3–2.2% |
| Web engine, playing (WebContent process only, `QTPlaybackLab --scenario power`) | 2.5% |
| Web engine, paused | 0.2% |
| Web engine, paused + frozen | 0.1% |

The web engine figure excludes the GPU process, so it understates. Either way, CPU is not a reason to switch
engines.

### Gapless

- **Scheduler.** An offline render plays a track straight through, and also cut in two at the midpoint with both
  segments scheduled back to back on one node. The two outputs are **identical**: max |difference| = 0.0 over 88,200
  frames on 3 tracks, with no silent frames at the cut.
- **Encoder padding.** AudioToolbox reads YouTube's fragmented MP4 (`mp4f`) and honours its edit list. Decoded
  length = the URL's `dur` − 47.9 ms, which is exactly the 2,112 AAC priming frames, on all 23 tracks. So no padding
  lands at a seam.
- **Live.** With the next file enqueued behind the current one on a muted device, the longest silent run across the
  seam was 0 frames.

### Crossfade and EQ

- **Crossfade.** A 4 s equal-power ramp between two nodes ended at volume 1.0 / ~0, with the incoming track at
  4.3 s, as expected.
- **EQ.** The 10 bands (32 Hz–16 kHz) are applied live. The FFT returns 32 log-spaced bands, and 89–100 of 100 polls
  had signal; the rest fell in quiet intros.

### Formats AVFoundation can play

| Format | Result |
|---|---|
| AAC (139/140/141) in fragmented MP4 | plays directly with `AVAudioFile` and `AVPlayer` |
| Opus in WebM (249/250/251/774) | `AVURLAsset.isPlayable == false` |

AudioToolbox can decode Opus, but nothing in AVFoundation demuxes WebM. Using 774 would need our own WebM demuxer
feeding `AVAudioConverter`. AAC 256 is good enough that this isn't worth it.

## 4. Maintenance burden (how often it breaks)

- **Measured in this one session.**
  - ANDROID_VR went from working to bot-checked within minutes.
  - Updating IOS and ANDROID to current versions turned them SABR-only.
  - TVHTML5 rejects the signed-in session.
  - The 2025-era client versions we started with already gave different results from the current ones.
- **yt-dlp, the best public proxy for churn.** In the last 12 months (2025-10 → 2026-10) yt-dlp put out 13 releases
  with **36 YouTube playback-related changelog entries**:
  - client additions and removals: `tv_downgraded`, `visionos`, `web_embedded` fallbacks, `android_vr` removed from
    the defaults;
  - "Player client maintenance" and "Update player client versions";
  - forced player versions;
  - six EJS solver updates (0.3.2 → 0.8.0).
  - Nightly hotfixes come on top of these. YouTube changes something that matters to stream extraction about
    **every 2–4 weeks**, and some changes break every client at once until a fix ships.
- **What we would own.**
  - The client table.
  - PO-token and bot-check fallbacks.
  - The solver: vendored EJS that has to be updated with yt-dlp's releases, or our own AST matcher, which is a
    permanent arms race.
  - A SABR/UMP implementation once WEB_REMIX drops classic URLs.
  - URL expiry (about 6 h) and re-resolution.
  - Error mapping.
  - For every breakage, a quick hotfix release and automatic fallback to the web engine.

  A realistic estimate is 2–3 weeks to build, then about a day a month of maintenance, with some urgent weeks.
- **Third-party code.** Shipping the solver means vendoring yt-dlp/ejs (Unlicense), which bundles meriyah (ISC) and
  astring (MIT): about 370 KB of JS. That is a new dependency and **needs your approval**.

## 5. YouTube's Terms of Service, honestly

- YouTube's Terms of Service forbid accessing, downloading or otherwise using any part of the Service or its
  Content except as the Service expressly authorizes. They also forbid accessing it by automated means, and
  circumventing or interfering with any part of the Service, including its security features. (Older versions of
  the Terms said it directly: content only "through the video playback pages of the Service, the Embeddable
  Player, or other explicitly authorized means".)
- Every step of the native path is exactly what the Terms forbid:
  - pretending to be another client (spoofing its InnerTube identity);
  - solving the signature and `n` challenges;
  - fetching googlevideo media directly, and downloading it.
- **Premium does not change this.** It buys ad-free playback in official clients and offline downloads inside the
  official apps. It does not license third-party extraction.
- **Practical risks.**
  - Google can revoke the session or flag the account. This is rare for personal use, but the signed-in session
    makes it attributable.
  - Streams can stop working without notice.
  - Distributing an app built on this exposes the developer: anti-circumvention arguments were the basis of the
    2020 RIAA takedown of youtube-dl, which was later reversed.
  - Native playback would also skip YouTube's playback reporting. Plays would not count toward the user's
    history and recommendations unless we imitate the official client's tracking pings, which is a further step
    in the same direction.
- **The web engine, by comparison,** runs YouTube Music's own web player, served by music.youtube.com, inside a
  WKWebView. Ads still play for free accounts, and YouTube's own code fetches and reports the media. That is much
  closer to the "playback pages of the Service". It is still an unofficial client, but it isn't extraction.

## 6. Options

| | What | Gets | Costs and risks |
|---|---|---|---|
| **A** | **Keep the web engine for everyone and improve it** | No ToS extraction, no cipher maintenance, plays count in history, free and Premium on one path. | No sample-exact gapless. EQ and visualizer only if Web Audio works in the page (see below). |
| **B** | **Native engine for Premium, as an opt-in "Experimental" setting** (Settings › Playback, off by default), falling back to the web engine automatically on any failure | Gapless, crossfade, EQ, visualizer data, AAC 256. | Everything in §4 and §5. Needs approval to vendor EJS. Plays don't reach history unless we fake playback reporting. |
| **C** | **Native by default for Premium** | Same as B, for everyone with Premium. | Same as B, plus every YouTube change becomes a visible outage for most users. **Not recommended.** |
| **D** | **Don't build anything native; drop the Premium-only features** | Simplest. | Visualizer, EQ, crossfade and gapless are greyed out for everyone. |

**Recommendation: A, with a short follow-up spike, and keep B on the shelf.**

- **Follow-up spike: Web Audio inside the web engine.**
  - YouTube's page plays through a normal `<video>` element fed by MediaSource. Browser EQ extensions attach
    `createMediaElementSource` → `BiquadFilterNode` × 10 → `AnalyserNode` to it.
  - If that works in our WKWebView, the web engine gets the **EQ** and **visualizer data** too: spectrum bridged to
    native at display rate, or at a lower rate.
  - A second, preloaded web player with a volume ramp could give a **crossfade**.
  - Sample-exact gapless would stay native-only.
  - Not tested yet.
- **B only with your explicit go-ahead.** Take this path only if you accept the ToS risk and the maintenance in
  writing, and approve vendoring EJS. The spike code is a working start for it: about 2–3 weeks to production
  quality.

**Your call:** A, B, C or D, and whether to run the Web Audio spike.

**Update (web-audio):** the Web Audio follow-up ran; see `docs/web-audio.md`. A Web Audio graph can't process the
page's audio in WKWebView, because a realtime `AudioContext` doesn't render while media runs in the WebContent
process, and an MSE `<video>` gives a media-element source silence. What did work: the web engine now decodes the
audio the page appends to its MediaSource for the visualizer, so **visualizer data is available for every
account**. EQ and crossfade stay native-only. A Core Audio process tap could add EQ, at the cost of a system
permission prompt; that is your call.

## 7. If B is chosen: what's left

1. Wire `QTNativePlaybackEngine` (in `QTPlaybackEngineSelector.swift`) to the resolver and graph:
   - `isAvailable` follows the opt-in setting and the account tier;
   - map states and errors onto `QTPlaybackState` / `QTPlaybackError`;
   - seeking through `scheduleSegment`;
   - volume and mute on the main mixer.
2. **Prefetch** the next queue item (resolve + download) for gapless, and for TTFA ≈ 0 on skips. Cache the
   preprocessed player per hash on disk. Re-resolve when a URL expires.
3. Stream instead of downloading whole files, if lower TTFA matters:
   - `AudioFileStream` handles fMP4 fragments;
   - or `AVAssetResourceLoader` plus `MTAudioProcessingTap` on `AVPlayer`.

   Today's 0.66 s median is already good.
4. Vendor EJS, after approval, with a version pin and an update script. Show the "Experimental" setting with a
   one-line description. Fall back to the web engine on any 403, bot check or solver failure, and remember the
   failure for the session.
5. Decide on playback reporting: none (history doesn't learn) or imitating `videostatsPlaybackUrl` pings.
6. Don't write audio to disk in release builds. Keep it in memory or purge it immediately; a full-file cache is a
   download in the ToS sense.
7. Plan for SABR: when WEB_REMIX stops returning URLs, B stops working until UMP is implemented.

## 8. Build-out (option B, 2026-10-19)

How each step of §7 was done. Architecture notes: `docs/architecture.md` (QTPlayback row, *Engine*, *Next item*).

| §7 step | Done as |
|---|---|
| 1. Wire the engine | `QTNativePlaybackEngine` wraps the app's `QTWebPlaybackEngine`. Songs play natively; Video items, item-level failures and every load after a systemic failure go to the web engine. `QTNativeEngineCoordinator` swaps it in when Settings › Playback › **Native engine** is on, the session is signed in and Premium, and playback uses that session. It swaps back when any of those stops being true. States and errors map onto `QTPlaybackState`; seek, volume and mute go to the graph. Capabilities are `.premium` until a fallback, then `.web`. |
| 2. Prefetch, cache, re-resolve | `QTQueueController.prepareNext` names the next item after every queue edit. The engine fetches its audio into memory (`QTNativeAudioFetcher`, LRU of 4) and joins it gaplessly or crossfades into it. The queue follows through `QTPlaybackItem.queueID`, without a load. Preprocessed players are cached per hash in Caches (`QTNativePlayerCache`), so a known player costs one tiny hash check. Resolved URLs are reused until two minutes before `expire`. A 403/410 or a failed solve gets one retry with a re-checked player. |
| 3. Streaming | Not done: the median start was already low. Whole files download into memory; decoding runs about 1 s ahead in 8,192-frame buffers. |
| 4. Vendor EJS, fallback | EJS 0.8.0 lives in `Sources/QTPlayback/Resources/EJS`, pinned by `VERSION` + `CHECKSUMS`; `Scripts/update-ejs.sh` checks it or moves the pin. A 403, bot check, solver failure or SABR-only answer → `fallbackReason`, and the rest of the session plays in YouTube's player. Settings says so; there is no toast. |
| 5. Playback reporting | None. Native plays don't reach the account's history (the user accepted this). |
| 6. No audio on disk | `QTNativeMemoryAudioFile` decodes from `Data` through AudioToolbox read callbacks + ExtAudioFile. The spike's file downloader is DEBUG-only. |
| 7. SABR | Unchanged. When WEB_REMIX goes SABR-only, the engine falls back automatically and stays fallen back. |

Also built:
- **Song⇄Video.** Song→Video keeps the native song playing while the video page loads muted. The page is then lined up with the native clock (held, or seeked once) and the audio swaps. Video→Song starts native at the page's position, then freezes the page.
- **Album-aware transitions.** Two tracks from one album join gaplessly even with crossfade on.
- **Loudness.** YouTube's `loudnessDb` turns loud tracks down, as its own player does, so the two engines sound equally loud.
- **Visualizer.** The FFT tap runs only while something asks for the spectrum.
- **Output changes.** A device change (headphones, AirPlay, sample rate) restarts the graph at the same position.

### Measured (debug build, Premium session, output silent; `Scripts/native-acceptance.py`, 21/21 checks)

| | Result |
|---|---|
| Tracks in a row, natively | 12/12, no stall, all AAC 256 (itag 141) |
| Gapless | 12 seams over 12 advances. The new track was at 0.03–0.04 s when the seam was reported (output latency). Offline render of a chained deck = the two decodes back to back (max difference < 1e-5, no silence at the seam). |
| Start, request → first rendered frame | From memory (prefetched next, Previous): 0.08–0.12 s. From the network: typically ~1 s (0.24–2.2 s). Cold first track: 1.0–1.4 s with a cached player, 2.5–3.4 s without one. |
| Crossfade (5 s) | The next track started 4.5 s after seeking to 9 s before the end (≈ 4 s expected; status-file polling granularity) |
| EQ | Bass Booster vs Treble Booster shifted the spectrum's low/high balance (0.320/0.135 vs 0.250/0.203) |
| Song→Video | 1.6–4.1 s until the swap, with the song playing throughout; the two clocks were −0.04…+0.04 s apart at the swap |
| Video→Song | 0.02–0.04 s |
| Opt-in toggled mid-song | Off → YouTube's player continues the same song; on → native again |
| Now Playing | One entry for the app, none from WebKit, before and after Song⇄Video |
| CPU while playing (app + WebContent, 10 s, UI and status polling included) | Native 4.2–5.4 % + 0.1 %, vs the web engine 6.7 % + 3.4 % |
| Forced solver failure | Systemic fallback; the next tracks played in YouTube's player |
