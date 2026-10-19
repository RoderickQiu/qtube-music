# Web engine audio: visualizer data, EQ, crossfade

*Follow-up to `docs/native-engine-spike.md` §6 (option A: keep the web engine and add audio processing inside
the player page). Measured 2026-10-19 on macOS 27 (arm64) with `QTPlaybackLab`, anonymous and silent.*

**Result.** The visualizer is now audio-reactive on the web engine, for every account. EQ and crossfade can't be
done inside the page and stay native-only. Gapless stays native-only too.

| Feature | Web engine | How |
|---|---|---|
| Visualizer data (`.visualizerData`) | **yes**, free and Premium | spectrum decoded from the audio the page feeds its MediaSource |
| EQ (`.equalizer`) | no | Web Audio can't process the page's audio (below) |
| Crossfade (`.crossfade`) | no | YouTube's player has one media element; a second player page is a second YouTube Music page |
| Gapless (`.gapless`) | no | unchanged |

## 1. Why the prescribed Web Audio graph doesn't work

The plan was `MediaElementAudioSourceNode` → 10 × `BiquadFilterNode` → gain → destination, with an `AnalyserNode`
before the mute gain. Measured in the engine's own page:

- **A realtime `AudioContext` never renders while media runs in the WebContent process.** The engine runs media
  there on purpose, so that WebKit never publishes its own Now Playing entry (`QTWebKitTuning`). In that mode
  `state` says `running`, but `currentTime` stays 0. An oscillator → analyser reads zeros, and so does a plain
  WAV `<audio>`. `OfflineAudioContext` does render.
  - A minimal page outside YouTube reproduces this: `currentTime` is 0 with GPU-process media off, and 1.5 s
    with it on.
- **With GPU-process media on, the context renders, but YouTube's `<video>` gives silence.**
  `createMediaElementSource` on the MediaSource-fed (MSE) video reads zeros at element volume 0, at volume 1 and
  muted. WebKit has no audio source provider for MSE playback.
- **GPU-process media also brings back the duplicate Now Playing entry.** The system's Now Playing path showed
  `com.apple.WebKit.GPU` as soon as the element was unmuted (Kaset bug #457).

So a Web Audio graph can neither analyse nor equalise the page's audio, in either process mode.

## 2. What ships: the spectrum tap

`Sources/QTPlayback/Web/Audio/`:

- `QTWebAudioScript.parsers`: pure container parsing, unit-tested in JavaScriptCore. It reads WebM (EBML,
  Cluster/Timecode, TimestampScale) and MP4 (moof/tfdt, mdhd timescale), and detects encryption.
- `QTWebAudioScript.tap`: the page side. It is installed at document start, before the bridge.
  - It wraps `MediaSource.prototype.addSourceBuffer`, for audio SourceBuffers only.
  - It keeps a copy of every byte the page appends, at most 12 MB per track, oldest dropped.
  - It indexes each cluster or fragment start by its **container timestamp** plus `timestampOffset`. YouTube
    slices its appends anywhere, often through a cluster header. Indexing by timestamp means the slicing doesn't
    matter, and neither do seeks.
  - `frames(bands, ahead, dt)` does the following:
    - decodes the whole clusters that cover about 6 s around the playhead (`decodeAudioData` on an
      `OfflineAudioContext`, at 24 kHz mono);
    - starts decoding the next window 2 s before the current one ends;
    - returns 2048-point FFTs (Hann window, 48 log-spaced bands from 40 Hz to 12 kHz, +3 dB per octave tilt,
      −66…−6 dB mapped to 0…1) for the playhead and the next `ahead` frames, `dt` apart.
  - If there are no spectra, it returns a reason instead: `paused`, `pending`, `nodata`, `protected` or
    `undecodable`.
  - `release()` drops the decoded audio.
- `QTWebAudioTap`: the native side, owned by `QTWebPlaybackEngine.audio`.
  - It is driven by pulls. The visualizer calls `spectrum(bandCount:)` once per frame, only while it is on screen
    and playing.
  - About every 100 ms one of those calls pulls a batch of 10 frames at 60 fps (about 170 ms, so batches
    overlap).
  - The batch is anchored at the midpoint of its round trip, and each call returns the frame for its own
    uptime. The result is display-rate bars from about 10 page calls a second.
  - It releases the page 1 s after the last call.
- **Degradation.**
  - While decoding, after a seek, or between items, the bands read 0, which is the visualizer's resting shape.
  - For encrypted or undecodable media, `spectrum` returns nil and the visualizer runs its own synthetic
    animation.

The tap is independent of the output path:

- **Nothing is routed.** The media element, its volume, mute, ads and Now Playing are untouched.
- **Mute and silent mode don't matter.** The spectrum comes from the stream itself, before every gain stage, so
  muted playback and the engine's silent test mode still drive the visualizer (checked).
- **No cross-origin problem.** The tap reads bytes the page itself appended, never a media element, so nothing can
  be tainted.
- **No timers in the page.** A hidden page's DOM timers are throttled: an interval of 16 ms fired about 4 times
  a second by default, and a long-running one about 20 times a second even with alignment off. Pulling from
  native avoids all of that.

### Measured (`QTPlaybackLab --scenario spectrum`)

The scenario plays Despacito anonymously, silent, with `audio/webm; codecs="opus"`. It polls `spectrum(bandCount: 96)`
at 60 fps the way the Stage visualizer does.

| Check | Result |
|---|---|
| Frames with signal while the visualizer asks | 100% of 300 |
| Bars move frame to frame | mean \|Δ\| 0.028 per band |
| Muted (`setMuted(true)`) | still has data |
| Seek to 1:00 | data again within 2.5 s |
| Nobody asks for 1 s | page released (`on: false`, decoded audio dropped) |
| Page work per batch | under 0.1 ms per frame; one decode of 6 s is about 20–25 ms |
| Sanity check (bad guy, 0:27) | 40 Hz band −18 dB: real sub-bass. Despacito's guitar intro is around −80 dB below 100 Hz, as expected |

CPU, as process user + system time over 10 s, one core = 100%:

| State | WebContent | App (lab) |
|---|---|---|
| Playing, visualizer hidden | 2.1–2.4% | 0.3% |
| Playing, visualizer visible (60 fps) | 2.9% | 1.3% (includes the lab's own 60 Hz poll) |
| Playing, visualizer hidden again | 2.0% | 0.3% |

Hidden costs nothing measurable. Visible adds about 1% to WebContent, plus the app's IPC. The first version, a
60 Hz pull of single frames, cost +4% and +2%.

In the app, the Stage visualizer on the built-in display (mock catalog through the web engine, anonymous, silent)
was A/B tested with `-qt.webaudio.tap NO`, which turns the tap off; the visualizer then animates synthetically.
The rest of the setup was the same, with 10 s windows. Other agents' app instances were running, so the app
numbers are noisy.

| | WebContent | App |
|---|---|---|
| Visualizer, tap off | 2.7–2.8% | 22.9–25.6% |
| Visualizer, tap on (about 10 pulls/s, 48 bands) | 4.8–5.0% | 18.9–26.7% (no measurable difference) |
| Blur background (no visualizer: tap idle, 0 pulls) | 2.4% | 17.9% |

The app's own visualizer cost is the Metal renderer at 60 fps, which was there before. The tap adds about 2% to
WebContent, and only while the visualizer is on screen.

Reproduce:

```sh
swift run --scratch-path .build/<you> QTPlaybackLab --scenario spectrum --ids kJQP7kiw5Fk
```

## 3. EQ and crossfade: what would be needed

- **EQ on the web engine** needs the audio *after* WebKit plays it. The only system route is a **Core Audio
  process tap** (macOS 14.2+):
  - `AudioHardwareCreateProcessTap` on the WebContent process, muted while tapped;
  - an aggregate device;
  - the 10-band EQ in `AVAudioEngine`, played back out.

  It works with any account and any codec. But the user gets the "System Audio Recording" permission prompt, it
  adds output latency, and it is a new playback path to maintain. **This is your call**; not built.
- **Crossfade** would need a second, preloaded player page that ramps its volume while the first fades. That is a
  second full YouTube Music page, with its own ads, CPU and network, and two pages in the account's session.
  Not worth it; crossfade stays native-only.

## 4. Capability and UI changes

- `QTPlaybackCapabilities.web` = video, AirPlay, visualizer data. `QTWebPlaybackEngine.capabilities` and
  `QTPlaybackEngineSelector.capabilities(of: .web, …)` return it.
- The simulated engine's free tier mirrors the web engine, because that is what a free account really plays
  through.
- The Stage's visualizer gate follows the playing engine's capabilities, not the account tier:
  `QTStageResolvedAppearance(…, hasVisualizerData:)` and the Appearance popover. So free accounts get the
  visualizer.
- Settings › Playback is unchanged: gapless, crossfade and EQ are still greyed out on the web engine, with its
  note.
