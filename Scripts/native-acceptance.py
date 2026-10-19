#!/usr/bin/env python3
"""Acceptance for the native Premium engine (docs/native-engine-spike.md, option B), in the bundled app, silent.

    QT_VARIANT=<name> Scripts/build-app.sh
    QT_VARIANT=<name> Scripts/native-acceptance.py [--plays 12] [--keep] [--only plays,crossfade,…]

Launches the app variant in the background on the test display with the user's library and saved session
(`-qt.catalog live`, signed-in), the native engine opted in for the session (`-qt.playback.native YES`) and output
silent (scripted runs: web media pinned to 0, native output volume 0). Then, all through the DEBUG hooks (no input,
no focus changes):

  * plays: N tracks in a row natively, seeking near each end — no stall, each one native, gapless seams counted;
  * seek and pause/play on the native clock;
  * crossfade: 5 s crossfade, the next track starts ~5 s before the end;
  * EQ: Bass Booster vs Treble Booster move the spectrum's low/high balance (the tap sits after the EQ);
  * Song⇄Video: song → video hands over to the web engine without resetting the position, and back to native;
  * Now Playing: exactly one entry for the app, none from WebKit;
  * CPU of the app (+ its WebContent process) while native plays;
  * fallback: a forced solver failure makes the next resolve fall back to YouTube's player for the session, and
    playback carries on.

Plays here are native: nothing is reported to YouTube (no history entries). Prints PASS/FAIL lines and writes
.build/native-acceptance.json.
"""
import argparse
import importlib.util
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True  # no Scripts/__pycache__ from importing the sibling script
spec = importlib.util.spec_from_file_location("pa", os.path.join(HERE, "playback-acceptance.py"))
pa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pa)


class NativeRun(pa.Run):
    def launch(self, relaunch=False):
        for stale in (self.ready_path, self.status_path):
            if os.path.exists(stale):
                os.remove(stale)
        pa.sh("pkill", "-f", f"^{pa.EXE}")
        time.sleep(0.5)
        args = ["-ApplePersistenceIgnoreState", "YES", "-qt.screen", pa.SCREEN, "-qt.readyFile", self.ready_path,
                "-qt.playback.statusFile", self.status_path, "-qt.lang", "en-US", "-qt.panelTab", "now-playing",
                "-qt.catalog", "live", "-qt.playback.native", "NO" if self.args.web else "YES", "-qt.playback.persist", "NO",
                "-qt.paused", "NO", "-qt.time", "20", "-qt.player.repeat", "all"]
        pa.subprocess.run(["open", "-g", "-n", pa.APP, "--args", *args], check=True)
        end = time.time() + 90
        while time.time() < end and not os.path.exists(self.ready_path):
            time.sleep(0.2)
        self.restore_focus()
        with open(self.ready_path) as f:
            ready = json.load(f)
        if "error" in ready:
            raise SystemExit(f"app refused to launch: {ready['error']}")
        self.pid = ready["pid"]
        self.log(f"launched pid {self.pid} ({pa.BUNDLE}); status file {self.status_path}")

    def native(self, s=None):
        return (s or self.status()).get("native") or {}

    def wants(self, part):
        return not self.args.only or part in self.args.only.split(",")

    def wait_native_playing(self, timeout=60, video_id=None):
        def ok(x):
            n = x.get("native") or {}
            return (n.get("active") and x.get("isPlaying") and n.get("position", -1) > 0.2
                    and (video_id is None or x.get("videoID") == video_id))
        return self.wait(timeout, "native playing", ok)

    def progress(self, seconds=2.0):
        """(position before, position after, rate): the native clock against the status file's own uptime stamps
        (the file is rewritten every 0.5 s, so wall time between reads would be off by up to that)."""
        sa = self.status()
        time.sleep(seconds)
        sb = self.status()
        a, b = self.native(sa).get("position", -1), self.native(sb).get("position", -1)
        du = sb.get("uptime", 0) - sa.get("uptime", 0)
        return a, b, ((b - a) / du if du > 0.2 else None)

    def web_baseline(self):
        """The same CPU measurement with YouTube's player (opt-in off), for comparison."""
        self.launch()
        s = self.wait(90, "web playing", lambda x: x.get("isPlaying") and not x.get("isBuffering") and x.get("time", 0) > 21)
        if not s:
            self.check("web baseline: playing", False)
            return
        time.sleep(3)
        s = self.status()
        pids = [self.pid] + ([s["webContentPID"]] if s.get("webContentPID") else [])
        a = [pa.cpu_time(p) or 0 for p in pids]
        time.sleep(10)
        b = [pa.cpu_time(p) or 0 for p in pids]
        app = (b[0] - a[0]) / 10 * 100
        wc = (b[1] - a[1]) / 10 * 100 if len(pids) > 1 else 0
        self.cpu = {"app": round(app, 1), "webContent": round(wc, 1)}
        self.check("web baseline CPU (app + WebContent, 10 s)", True, f"app {app:.1f}% + WebContent {wc:.1f}%")
        self.report = {"results": self.results}

    def run(self):
        if self.args.web:
            return self.web_baseline()
        self.launch()
        s = self.wait(60, "native engine in", lambda x: x.get("native", {}).get("active"))
        st = self.status()
        self.check("native engine plays (opted in, Premium, signed in)", bool(s),
                   f"eligible={st.get('nativeEligible')} optIn={st.get('nativeOptIn')} native={st.get('native')} "
                   f"status={st.get('status')} failure={st.get('lastFailure')}")
        if not s:
            return
        s = self.wait_native_playing()
        n = self.native(s)
        self.check("first track: native audio, AAC", bool(s) and n.get("itag") in (139, 140, 141),
                   f"“{(s or {}).get('title')}” itag {n.get('itag')} start {n.get('startSeconds')} fetch {n.get('fetchSeconds')}")
        time.sleep(2)
        self.check_now_playing("native", self.status())

        if self.wants("seek"):
            send = pa.send
            send("seek:60")
            time.sleep(1.2)
            a, b, rate = self.progress(2.0)
            self.check("seek: lands and keeps playing", 60 <= a < 63 and rate and 0.9 < rate < 1.1,
                       f"{a:.2f} → {b:.2f}, rate {rate}")
            send("pause")
            time.sleep(0.8)
            a, b, rate = self.progress(1.5)
            st = self.status()
            self.check("pause: clock holds", st.get("status") == "paused" and abs(b - a) < 0.01, f"{a:.3f} → {b:.3f}")
            held = b
            send("play")
            time.sleep(0.8)
            a, b, rate = self.progress(1.5)
            self.check("play: clock resumes from where it held", self.status().get("isPlaying") and rate and 0.9 < rate < 1.1
                       and held <= a < held + 1.5, f"held {held:.2f}, then {a:.2f} → {b:.2f}, rate {rate}")

        if self.wants("plays"):
            self.plays()
        if self.wants("crossfade"):
            self.crossfade()
        if self.wants("eq"):
            self.eq()
        if self.wants("video"):
            self.video()
        if self.wants("requeue"):
            self.requeue()
        if self.wants("skips"):
            self.skips()
        if self.wants("toggle"):
            self.toggle()
        if self.wants("cpu"):
            self.cpu_check()
        if self.wants("fallback"):
            self.fallback()
        self.report = {"results": self.results, "native": self.native()}

    def plays(self):
        """N tracks in a row, natively: seek near each end, the next must start (gapless seam when prepared)."""
        pa.send("effects:crossfade:0")
        pa.send("effects:gapless:on")
        seams_before = self.native().get("gaplessSeams", 0)
        played, stalls = [], []
        for i in range(self.args.plays):
            s = self.wait_native_playing(45)
            if not s:
                st = self.status()
                stalls.append(f"{st.get('videoID')} status={st.get('status')} native={st.get('native', {}).get('active')}")
                break
            vid, hist = s["videoID"], s.get("historyCount", 0)
            played.append((vid, s.get("title"), self.native(s).get("itag")))
            # Give the next track time to prefetch, then jump near the end.
            self.wait(15, "next prepared", lambda x: len((x.get("native") or {}).get("fetchSeconds", [])) >= 1, interval=0.5)
            time.sleep(2.5)
            pa.send("seekEnd:5")
            r = self.wait(20, "next track", lambda x: x.get("historyCount", 0) > hist and x.get("videoID") != vid)
            if not r:
                st = self.status()
                stalls.append(f"no advance from {vid}: status={st.get('status')} pos={self.native(st).get('position')}")
                break
            self.log(f"play {i + 1}: {vid} “{s.get('title')}” itag {self.native(s).get('itag')} → {r.get('videoID')}")
        n = self.native()
        self.check(f"{self.args.plays} tracks in a row natively, no stall", len(played) == self.args.plays and not stalls,
                   f"played {len(played)}; stalls {stalls}; webLoads {n.get('webLoads')} itemFallbacks {n.get('itemFallbacks')}")
        seams = n.get("gaplessSeams", 0) - seams_before
        self.check("gapless: tracks joined on the node's timeline", seams >= max(1, len(played) - 2),
                   f"{seams} seams over {len(played)} advances; new track at {n.get('lastSeamPosition', -1):.3f} s when reported")
        starts = n.get("startSeconds", [])
        if starts:
            srt = sorted(starts)
            self.log(f"start (load → first frame): median {srt[len(srt) // 2]:.3f} s, max {srt[-1]:.3f} s over {len(srt)}")

    def crossfade(self):
        pa.send("effects:gapless:on")
        pa.send("effects:crossfade:5")
        s = self.wait_native_playing(30)
        if not s:
            self.check("crossfade: playing", False)
            return
        before = self.native(s).get("crossfades", 0)
        vid, hist = s["videoID"], s.get("historyCount", 0)
        self.wait(15, "next prepared", lambda x: True)
        time.sleep(3)
        dur = s.get("duration", 0)
        pa.send(f"seekEnd:9")
        t_seek = time.time()
        r = self.wait(15, "crossfade", lambda x: (x.get("native") or {}).get("crossfades", 0) > before, interval=0.1)
        took = time.time() - t_seek
        # The queue follows the engine on its next turn; the status file (every 0.5 s) may land in between.
        time.sleep(1)
        st = self.status()
        n = self.native(st)
        # The fade starts 5 s before the end: ~4 s after seeking to 9 s before it. Repeat One / same album → gapless.
        self.check("crossfade: next track starts ~5 s before the end", bool(r) and 2.5 < took < 6.0 and st.get("videoID") != vid,
                   f"after {took:.1f} s (expected ~4), {vid} → {st.get('videoID')}, crossfades {n.get('crossfades')}")
        pa.send("effects:crossfade:0")

    def eq(self):
        s = self.wait_native_playing(30)
        if not s:
            self.check("EQ: playing", False)
            return
        if s.get("duration", 0) - s.get("time", 0) < 30:
            pa.send("seek:30")
            time.sleep(1)
        def results(x):
            return [c for c in x.get("commands", []) if c.get("command") == "spectrum-result"]
        out = {}
        for preset in ("bassBooster", "trebleBooster"):
            pa.send(f"effects:eq:{preset}")
            time.sleep(0.6)
            before = len(results(self.status()))
            pa.send("spectrum")
            r = self.wait(6, "spectrum", lambda x: len(results(x)) > before)
            out[preset] = results(r)[-1] if r else {}
            time.sleep(0.3)
        pa.send("effects:eq:off")
        b, t = out.get("bassBooster", {}), out.get("trebleBooster", {})
        tilt_b = b.get("low", 0) - b.get("high", 0)
        tilt_t = t.get("low", 0) - t.get("high", 0)
        self.check("EQ: presets move the spectrum (Bass tilts low, Treble tilts high)",
                   b.get("samples", 0) > 10 and t.get("samples", 0) > 10 and tilt_b > tilt_t + 0.02,
                   f"bass low/high {b.get('low', 0):.3f}/{b.get('high', 0):.3f}, treble {t.get('low', 0):.3f}/{t.get('high', 0):.3f}")

    def video(self):
        """Song → Video (web engine, same position) → Song (native again). Tries tracks until one has a video."""
        for _ in range(4):
            s = self.wait_native_playing(40)
            if not s:
                break
            if s.get("duration", 0) - s.get("time", 0) < 40:
                pa.send("seek:20")
                time.sleep(1.5)
                s = self.status()
            pos = s.get("time", 0)
            hand = len(self.native(s).get("handovers", []))
            pa.send("mode:video")
            if not self.wait(3, "video mode", lambda x: x.get("mode") == "video"):
                pa.send("mode:song")
                hist = s.get("historyCount", 0)
                pa.send("next")
                self.wait(20, "next", lambda x: x.get("historyCount", 0) > hist)
                continue
            r = self.wait(30, "video handover", lambda x: len((x.get("native") or {}).get("handovers", [])) > hand
                          and not (x.get("native") or {}).get("active") and x.get("isPlaying"))
            st = self.status()
            t = st.get("time", 0)
            elapsed_ok = bool(r) and pos < t < pos + 40
            self.check("Song→Video: the web engine takes over, position carries on", elapsed_ok,
                       f"{pos:.1f} → {t:.1f} s; {(self.native(st).get('handovers') or ['-'])[-1]}; video {st.get('video')}")
            time.sleep(4)
            hand = len(self.native().get("handovers", []))
            pa.send("mode:song")
            r = self.wait(20, "song handover", lambda x: (x.get("native") or {}).get("active") and x.get("mode") == "song")
            st = self.status()
            self.check("Video→Song: back to native at the page's position", bool(r) and abs(st.get("time", 0) - (t + 4)) < 8,
                       f"now {st.get('time', 0):.1f} s; {(self.native(st).get('handovers') or ['-'])[-1]}")
            time.sleep(2)
            self.check_now_playing("after Song⇄Video", self.status())
            return
        self.check("Song⇄Video: a track with a music video", False, "none of 4 tracks had one")

    def requeue(self):
        """Up Next changes in the last second, when the old next track is already being scheduled behind this one:
        the new Up Next plays, not the one that was chained."""
        pa.send("effects:crossfade:0")
        s = self.wait_native_playing(30)
        if not s:
            return
        head = s.get("autoplayHead", [])
        if len(head) < 3:
            self.check("requeue: enough Autoplay", False, f"{head}")
            return
        chained, wanted = head[0], head[2]
        time.sleep(4)  # the next track is prefetched and chained
        hist = s.get("historyCount", 0)
        pa.send("seekEnd:0.7")
        time.sleep(0.25)
        pa.send(f"upnext:{wanted}")
        r = self.wait(20, "advance", lambda x: x.get("historyCount", 0) > hist and (x.get("native") or {}).get("active")
                      and x.get("isPlaying"))
        st = self.status()
        self.check("requeue: a late Up Next wins over the chained track", bool(r) and st.get("videoID") == wanted,
                   f"chained {chained}, Up Next {wanted}, now {st.get('videoID')}")

    def skips(self):
        """Next, Next again at once (the second one isn't prefetched yet: a network start), then Previous (memory)."""
        s = self.wait_native_playing(30)
        if not s:
            return
        starts_before = len(self.native(s).get("startSeconds", []))
        timings = []
        for cmd in ("next", "next", "previous"):
            hist = self.status().get("historyCount", 0)
            vid = self.status().get("videoID")
            t0 = time.time()
            pa.send(cmd)
            r = self.wait_native_playing(20) if cmd == "previous" else None
            if cmd != "previous":
                r = self.wait(20, cmd, lambda x: x.get("videoID") != vid and (x.get("native") or {}).get("active")
                              and x.get("isPlaying") and (x.get("native") or {}).get("position", 0) > 0.05, interval=0.1)
            timings.append((cmd, round(time.time() - t0, 2), (r or {}).get("videoID")))
            time.sleep(0.3 if cmd == "next" else 1)
        n = self.native()
        starts = n.get("startSeconds", [])[starts_before:]
        self.check("skips: Next / Next / Previous each start natively", all(t[2] for t in timings) and n.get("active"),
                   f"{timings}; engine load→first frame {[round(x, 3) for x in starts]}; fetch {[round(x, 3) for x in n.get('fetchSeconds', [])[-3:]]}")

    def toggle(self):
        """The opt-in goes off mid-song (YouTube's player takes over at the position) and on again (native back)."""
        s = self.wait_native_playing(30)
        if not s:
            return
        vid = s["videoID"]
        pa.send("native:off")
        r = self.wait(30, "web engine", lambda x: "native" not in x and x.get("isPlaying") and x.get("videoID") == vid)
        st = self.status()
        self.check("opt-in off: YouTube's player plays the same song on", bool(r),
                   f"“{st.get('title')}” at {st.get('time', 0):.1f} s, engine {'native' if 'native' in st else 'web'}")
        time.sleep(3)
        pa.send("native:on")
        r = self.wait(30, "native again", lambda x: (x.get("native") or {}).get("active") and x.get("isPlaying"))
        st = self.status()
        self.check("opt-in on: native again, same song", bool(r) and st.get("videoID") == vid,
                   f"“{st.get('title')}” at {st.get('time', 0):.1f} s")

    def cpu_check(self):
        s = self.wait_native_playing(30)
        if not s:
            return
        pids = [self.pid]
        web = s.get("webContentPID")
        if web:
            pids.append(web)
        a = [pa.cpu_time(p) or 0 for p in pids]
        time.sleep(10)
        b = [pa.cpu_time(p) or 0 for p in pids]
        app = (b[0] - a[0]) / 10 * 100
        wc = (b[1] - a[1]) / 10 * 100 if len(pids) > 1 else 0
        self.cpu = {"app": round(app, 1), "webContent": round(wc, 1)}
        self.check("CPU while native plays (app + WebContent, 10 s)", app + wc < 15,
                   f"app {app:.1f}% + WebContent {wc:.1f}% (status polling included)")

    def fallback(self):
        s = self.wait_native_playing(30)
        if not s:
            return
        pa.send("native:fail-solver")
        time.sleep(1)
        # The prepared next track may already be in memory; skip until a fresh resolve has to happen.
        for _ in range(3):
            hist = self.status().get("historyCount", 0)
            pa.send("next")
            self.wait(30, "next", lambda x: x.get("historyCount", 0) > hist)
            if self.native().get("fallbackReason"):
                break
            time.sleep(2)
        r = self.wait(40, "playing after fallback", lambda x: x.get("isPlaying") and not (x.get("native") or {}).get("active")
                      and (x.get("native") or {}).get("fallbackReason"))
        st = self.status()
        n = self.native(st)
        self.check("fallback: a solver failure hands playback to YouTube's player for the session", bool(r),
                   f"reason “{n.get('fallbackReason')}”, playing {st.get('isPlaying')} “{st.get('title')}”, toast “{st.get('toast')}”")
        if r:
            hist = st.get("historyCount", 0)
            pa.send("next")
            q = self.wait(40, "next on the web engine", lambda x: x.get("historyCount", 0) > hist and x.get("isPlaying")
                          and not (x.get("native") or {}).get("active"))
            self.check("fallback: the next track plays in YouTube's player too", bool(q), (q or {}).get("title", ""))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--plays", type=int, default=12)
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--only", default="", help="comma list: seek,plays,crossfade,eq,video,requeue,skips,toggle,cpu,fallback")
    ap.add_argument("--web", action="store_true", help="CPU baseline with YouTube's player instead (opt-in off)")
    ap.add_argument("--shots", default="")
    ap.add_argument("--signed-in", action="store_true", default=True)
    args = ap.parse_args()
    if not os.path.exists(pa.EXE):
        sys.exit(f"error: {pa.APP} not built (QT_VARIANT={pa.VARIANT} Scripts/build-app.sh)")
    run = NativeRun(args)
    try:
        run.run()
    finally:
        run.quit()
    report = getattr(run, "report", {"results": run.results})
    report["cpu"] = getattr(run, "cpu", None)
    out = os.path.join(pa.REPO, ".build", "native-acceptance.json")
    with open(out, "w") as f:
        json.dump(report, f, indent=2, ensure_ascii=False)
    failed = [r for r in run.results if not r["ok"]]
    print(f"\n== {len(run.results) - len(failed)}/{len(run.results)} checks passed == ({out})")
    for r in run.results:
        print(("PASS  " if r["ok"] else "FAIL  ") + r["check"] + (f" — {r['detail']}" if r["detail"] else ""))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
