# QTube Music — CPU budget (R4 "perf")

Budgets (spec §9): idle < 1 %; playing in the main window or on the Blur Stage < 8 % (app + WebContent);
visualizer < 15 %; video modes as low as possible.

## Method

`Scripts/perf-cpu.py` (debug app from `Scripts/build-app.sh`, the build every agent tests). It launches the variant
with `open -g -n`, mock catalog + mock lyrics, on the built-in 120 Hz Retina display (1440×900 pt window), and brings
it forward, so no other window covers it. Then it waits 8 s (12 s for the web engine) and reads `ps -o time` for the
app and its WebContent process at the start and end of a 30 s window. "Before" is commit 068eea0 built the same way
(`QT_VARIANT=perfbase`). Simulated-engine rows show the UI cost alone. Web-engine rows (`-qt.engine web`, anonymous,
muted, real music video ids) also count the YouTube player page. Other agents' builds and apps ran on the machine at
the same time, so expect about ±0.5 points of noise.

| Scenario (playing unless noted) | Before app | After app | Before WebContent | After WebContent |
|---|---:|---:|---:|---:|
| Idle (window, paused) | 0.9 | 0.6 | – | – |
| Window, panel on Now Playing (lyrics) | 13.1 | 2.1 | – | – |
| Window, panel on Queue | 21.4 | 2.1 | – | – |
| Blur Stage | 18.2 | 2.1 | – | – |
| Visualizer Stage (Metal, 60 fps) | 24.7 | 7.8 | – | – |
| Video Stage, MV still + Ken Burns + lyric line | 19.9 | 4.6 | – | – |
| Art-only Stage (current-lyric line) | 21.3 | 4.6 | – | – |
| Mini player | 13.7 | 0.7 | – | – |
| Window + desktop lyrics | 12.9 | 2.2 | – | – |
| **Web engine** · window | 13.6 | 2.5 | 2.4 | 2.5 |
| **Web engine** · Blur Stage | 20.0 | 1.9 | 2.2 | 2.2 |
| **Web engine** · Video Stage (real video) | 21.9 | 6.7 | 9.4 | 9.3 |

Every budget passes. The Blur Stage with the web engine went from 22.2 % to 4.1 % in total, and the visualizer
went from 24.7 % to 7.8 %.

## After the R4 integration (main, all six R4 branches merged)

Same method, default debug app, no other QTube instances, signed-out mock catalog, 30 s each (2026-10-19).
The web-engine visualizer now draws the real spectrum (web-audio tap), so its WebContent share is new.

| Scenario (playing unless noted) | App | WebContent |
|---|---:|---:|
| Idle (window, paused) | 0.7 | – |
| Window, panel on Now Playing | 2.0 | – |
| Window, panel on Queue | 2.2 | – |
| Blur Stage | 1.3 | – |
| Visualizer Stage (simulated spectrum) | 6.8 | – |
| **Web engine** · window | 2.6 | 2.5 |
| **Web engine** · Blur Stage | 1.7 | 2.3 |
| **Web engine** · Visualizer Stage (real spectrum) | 8.2 | 3.8 |
| **Web engine** · Video Stage (real video) | 6.7 | 11.0 |

Every budget still passes (web visualizer 12.0 % total against 15 %).

## After the R5 integration (main, all R5 branches merged)

Same method, default debug app, no other QTube instances, signed-out mock catalog, web engine (anonymous, muted),
30 s each (2026-10-19). Every run was recorded `"valid": true` (playing, on the engine asked for).

| Scenario (playing unless noted) | App | WebContent |
|---|---:|---:|
| Idle (window, paused) | 0.8 | – |
| **Web engine** · window | 2.5 | 2.1 |
| **Web engine** · Blur Stage | 1.8 | 2.0 |
| **Web engine** · Visualizer Stage (real spectrum) | 8.1 | 4.1 |

Every budget still passes (web window 4.6 %, Blur Stage 3.8 %, visualizer 12.1 % against 15 %).

## After the R6 integration (main, all R6 branches merged)

Same method, default debug app, no other QTube instances, signed-out mock catalog, web engine (anonymous, muted),
30 s each (2026-10-19). Every run was recorded `"valid": true`. The Queue row checks the new Core Animation
now-playing bars.

| Scenario (playing unless noted) | App | WebContent |
|---|---:|---:|
| Idle (window, paused) | 0.9 | – |
| Window, panel on Queue (simulated engine) | 1.9 | – |
| **Web engine** · window | 2.4 | 1.5 |
| **Web engine** · Blur Stage | 1.9 | 2.0 |
| **Web engine** · Visualizer Stage (real spectrum) | 7.7 | 4.8 |

Every budget still passes (web window 3.9 %, Blur Stage 3.9 %, visualizer 12.5 % against 15 %).

## Causes found (Time Profiler + SwiftUI instrument) and fixes

1. **`TimelineView(.periodic)` drove the whole window at the display's frame rate.** The SwiftUI instrument showed
   `UpdateFilter<PeriodicTimelineSchedule, QTScrubberContent>` running about 235 times a second for a 4 Hz
   scrubber. Each run was a full `NSHostingView.layout` → view-graph update → CA commit, which made up 90 % of
   main-thread samples. Removing just the scrubber's clock dropped the window from 14 % to 0.3 %.
   → `QTTickingView` (Shared/) sleeps between ticks. Scrubber, ad countdowns, mini-player progress and the menu-bar
   lyric all use it. It stops while its window is occluded and under the in-window Stage
   (`\.qtPausesTimeDrivenViews`), and while the Stage chrome has faded out.
2. **The current-lyric line (`TimelineView(.animation(minimumInterval: 1/20))`)** now redraws event-driven at the
   next word or line start (`QTStageCurrentLyric.secondsToNextChange`), not 20 times a second.
3. **SwiftUI `.symbolEffect(.variableColor.iterative)` on the Queue's now-playing glyph** re-rendered through the
   display list every frame (`InterpolatedDisplayList<Resolved>`, about 3.4k updates in 12 s), costing 15 %.
   → `QTNowPlayingGlyph` is an `NSImageView` with `addSymbolEffect`, and Core Animation runs the effect. The
   glyph looks the same. (R6: the marker is now `QTNowPlayingBarsView` — four `CALayer` bars on a keyframe loop,
   still the render server's job; window playing with the Queue tab and the Liked table both showing it: 1.4 % app.)
4. **Visualizer:** the `MTKView` now covers only the bottom half of the Stage (`heightFraction`; the shader lays
   things out against the full height, so the picture is unchanged — max pixel difference 2/255). It also stops its
   display link while its window is occluded.

No visual change: the before and after shots of the Blur Stage and the main window are pixel-identical
(`screenshots/r4-perf-blur-stage-*`, `r4-perf-window-*`). The visualizer differs by at most 2/255 (rounding).

## Left as is

- **Liquid Glass "flex" reaction.** `FlexCoreInteractionModifier` runs about 10 frames of glass animation after
  each scrubber tick inside the Stage's glass bottom bar. This is the system's behaviour, not ours, and costs well
  under 1 %.
- **Window snapshot on deactivation.** When the app deactivates, AppKit writes one window snapshot
  (`NSPersistentUI writeWindowSnapshot`, zlib, about 0.2 s). It happens once, not periodically.
- **Real video.** Video mode with the web engine costs about 6.7 % app and 9.3 % WebContent. The app side is WebKit's
  remote-layer commits for the video frames; the WebContent side is YouTube's player decoding the video.
- **Mini-player and menu-bar marquee.** `QTMarqueeText` still uses `TimelineView(.animation)`, but only while the
  pointer hovers and the title overflows.
- **Visualizer synthetic spectrum.** It allocates small arrays every frame, about 0.7 %. This is the path used
  until an engine reports a real spectrum.
