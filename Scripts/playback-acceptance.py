#!/usr/bin/env python3
"""M4 acceptance for real playback, in the bundled app, silent.

    QT_VARIANT=<name> Scripts/build-app.sh
    QT_VARIANT=<name> Scripts/playback-acceptance.py [--plays 10] [--lang en-US] [--shots PREFIX] [--keep] [--signed-in]

--signed-in: the user's library with the saved session (`-qt.catalog live`, signed-in playback — plays are recorded in
the account's YouTube Music history); also checks that the player page is signed in (Premium: no ads), that the
queue survives a relaunch (`-qt.playback.persist YES`, graceful quit) and that closing and reopening the main window
doesn't disturb playback. Without it the app plays whatever the default launch picks, anonymous only if the session
is missing.

Launches the app variant in the background on the test display (QT_SCREEN, else U270CA when connected, else
the built-in display) with the web engine playing the mock catalog's real
music videos (`-qt.engine web`, media volume pinned to 0 — never audible), then:

  * plays N tracks in a row (seeking near each end to save time, waiting out or skipping ads), failing on any
    stall (no progress for 45 s outside ads) — unplayable tracks must be skipped with a toast, not stall;
  * checks the system's Now Playing (Scripts/now-playing.sh, MediaRemote): exactly one client for the app,
    none for WebKit's GPU process, title/elapsed/rate/artwork matching the app;
  * drives play/pause/next through MPRemoteCommandCenter in-process (DEBUG hook) and through the system
    (MediaRemote command addressed to the app's own player only);
  * measures CPU (app + its WebContent process) while playing, paused (page frozen) and idle;
  * with --shots, captures the main window: playing (panel), Stage, ad, error toast (buffering: Scripts/shoot.sh
    with -qt.playback.readyWhen buffering).

Never activates the app; restores the frontmost app if it changed. Prints PASS/FAIL lines and writes a JSON
report to .build/playback-acceptance.json. Note: while it runs, the test app is the system's Now Playing app.
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VARIANT = os.environ.get("QT_VARIANT", "")
APP_NAME = "QTube Music" + (f" {VARIANT}" if VARIANT else "")
BUNDLE = "com.roderickqiu.qtube" + (f".dev-{VARIANT}" if VARIANT else "")
APP = os.path.join(REPO, ".build", "apps", APP_NAME + ".app")
EXE = os.path.join(APP, "Contents", "MacOS", "QTubeMusic")
NOTE = "com.roderickqiu.qtube.debug.playback"


def sh(*args, check=False, timeout=30):
    r = subprocess.run(list(args), capture_output=True, text=True, timeout=timeout)
    if check and r.returncode != 0:
        raise RuntimeError(f"{args[0]} failed: {r.stderr.strip()}")
    return r.stdout.strip()


def lib(expr):
    return sh("bash", "-c", f'source "{REPO}/Scripts/lib.sh"; {expr}', check=True, timeout=300)


SCREENSHOTS = lib('echo "$QT_SCREENSHOTS"')
WINDOW_TOOL = lib("qt_tool qt-window-id")
# QT_SCREEN, else U270CA when connected, else the built-in display; a QT_SCREEN that isn't connected stops the run
# (the DEBUG app refuses such a launch as well, instead of opening on another display).
SCREEN = lib("qt_screen")


def frontmost():
    return sh("osascript", "-e", 'tell application "System Events" to get bundle identifier of first process whose frontmost is true')


def now_playing(mode, *extra):
    out = sh(os.path.join(REPO, "Scripts", "now-playing.sh"), mode, *extra, timeout=20)
    try:
        return json.loads(out.splitlines()[-1])
    except (ValueError, IndexError):
        return {"error": out}


def send(command):
    script = ('ObjC.import("Foundation"); $.NSDistributedNotificationCenter.defaultCenter'
              f'.postNotificationNameObjectUserInfoDeliverImmediately("{NOTE}", "{BUNDLE}", $({{command: "{command}"}}), true)')
    sh("osascript", "-l", "JavaScript", "-e", script)


def cpu_time(pid):
    out = sh("ps", "-o", "time=", "-p", str(pid))
    if not out:
        return None
    total = 0.0
    for part in out.split(":"):
        total = total * 60 + float(part)
    return total


class Run:
    def __init__(self, args):
        self.args = args
        self.results = []
        self.status_path = tempfile.mktemp(prefix="qt-playback-status-", suffix=".json")
        self.ready_path = tempfile.mktemp(prefix="qt-playback-ready-", suffix=".json")
        self.t0 = time.time()
        self.pid = None
        self.front_before = frontmost()
        self.shots_taken = set()

    def log(self, msg):
        print(f"{time.time() - self.t0:7.1f}  {msg}", flush=True)

    def check(self, name, ok, detail=""):
        self.results.append({"check": name, "ok": bool(ok), "detail": detail})
        self.log(f"{'PASS' if ok else 'FAIL'}  {name}" + (f" — {detail}" if detail else ""))

    def status(self):
        try:
            with open(self.status_path) as f:
                return json.load(f)
        except (OSError, ValueError):
            return {}

    def wait(self, timeout, what, cond, interval=0.25):
        end = time.time() + timeout
        while time.time() < end:
            s = self.status()
            if s and cond(s):
                return s
            time.sleep(interval)
        self.log(f"timeout: {what}")
        return None

    # MARK: launch / quit

    def launch(self, relaunch=False):
        for stale in (self.ready_path, self.status_path):
            if os.path.exists(stale):
                os.remove(stale)
        sh("pkill", "-f", f"^{EXE}")
        time.sleep(0.5)
        args = ["-ApplePersistenceIgnoreState", "YES", "-qt.screen", SCREEN, "-qt.readyFile", self.ready_path,
                "-qt.engine", "web", "-qt.playback.statusFile", self.status_path, "-qt.lang", self.args.lang,
                "-qt.panelTab", "now-playing"]
        if not relaunch:
            args += ["-qt.paused", "NO", "-qt.time", "20", "-qt.player.repeat", "all"]
        if self.args.signed_in:
            args += ["-qt.catalog", "live", "-qt.playback.persist", "YES"]
        subprocess.run(["open", "-g", "-n", APP, "--args", *args], check=True)
        end = time.time() + 90
        while time.time() < end and not os.path.exists(self.ready_path):
            time.sleep(0.2)
        self.restore_focus()
        with open(self.ready_path) as f:
            ready = json.load(f)
        if "error" in ready:
            raise SystemExit(f"app refused to launch: {ready['error']} ({ready.get('screen')}; connected: "
                             f"{', '.join(ready.get('screens', []))})")
        self.pid = ready["pid"]
        self.log(f"launched pid {self.pid} ({BUNDLE})")

    def quit_gracefully(self):
        """Quit through the app (an Apple Event, no activation) so it flushes the queue like a real quit."""
        sh("osascript", "-e", f'tell application id "{BUNDLE}" to quit')
        end = time.time() + 15
        while time.time() < end and sh("ps", "-p", str(self.pid), "-o", "pid="):
            time.sleep(0.3)
        self.restore_focus()

    def quit(self):
        if self.pid and not self.args.keep:
            sh("kill", str(self.pid))
            time.sleep(1.5)
            sh("kill", "-9", str(self.pid))
        self.restore_focus()

    def restore_focus(self):
        now = frontmost()
        if self.front_before and now != self.front_before and now.startswith("com.roderickqiu.qtube"):
            self.log(f"focus moved to {now}; restoring {self.front_before}")
            sh("osascript", "-e", f'tell application id "{self.front_before}" to activate')

    # MARK: screenshots

    def shot(self, name):
        if not self.args.shots or name in self.shots_taken:
            return
        # The main window is titled after its page; without --title the tool takes the largest window (main).
        wid = sh(WINDOW_TOOL, "--pid", str(self.pid), "--wait", "3")
        if not wid:
            self.log(f"no window for shot {name}")
            return
        path = os.path.join(SCREENSHOTS, f"{self.args.shots}-{name}.png")
        for _ in range(12):
            sh("screencapture", f"-l{wid}", "-o", "-x", path)
            width = sh("sips", "-g", "pixelWidth", path).split()[-1]
            if width.isdigit() and int(width) >= 1000:
                break
            time.sleep(0.5)
        self.shots_taken.add(name)
        self.log(f"shot {path}")

    # MARK: checks

    def check_now_playing(self, label, s):
        clients = now_playing("clients").get("clients", [])
        ours = [c for c in clients if c.get("bundleIdentifier") == BUNDLE]
        webkit = [c for c in clients if c.get("parentApplicationBundleIdentifier") == BUNDLE]
        self.check(f"{label}: exactly one Now Playing entry, none from WebKit", len(ours) == 1 and not webkit,
                   f"ours={len(ours)} webkit={len(webkit)} all={[c.get('description') for c in clients]}")
        item = now_playing("item")
        owner = (item.get("activeClient") or {}).get("bundleIdentifier")
        meta = item.get("item", {})
        s = self.status()
        if owner != BUNDLE:
            self.check(f"{label}: system Now Playing shows the app", False, f"active player is {owner}")
            return
        elapsed = meta.get("elapsedTime", -1)
        rate = meta.get("playbackRate", 0)
        # The system extrapolates elapsed from its timestamp at the given rate.
        stamp = meta.get("elapsedTimeTimestamp")
        if stamp is not None and rate:
            elapsed += (item.get("now", 0) - (stamp + 978307200)) * rate
        app_time = s.get("time", 0)
        if s.get("isPlaying") and not s.get("isBuffering"):
            app_time += time.time() - os.path.getmtime(self.status_path)
        drift = abs(elapsed - app_time)
        self.check(f"{label}: Now Playing title, artwork, elapsed", meta.get("title") == s.get("title") and meta.get("artworkAvailable")
                   and drift < 1.5, f"“{meta.get('title')}” elapsed {elapsed:.1f} vs app {app_time:.1f} (drift {drift:.2f}s), "
                   f"rate {rate}, artwork {meta.get('artworkAvailable')}")

    def wait_for_content(self, timeout=100):
        """Content (not an ad) playing with time advancing; skips ads as soon as allowed."""
        end = time.time() + timeout
        last_t, last_change = None, time.time()
        saw_ad = False
        while time.time() < end:
            s = self.status()
            ad = s.get("ad")
            if ad:
                saw_ad = True
                if ad.get("duration", 0) > 0:
                    self.shot("ad")
                if ad.get("canSkip"):
                    send("skipAd")
                    time.sleep(1)
            if s.get("toast") and s.get("lastFailureMessage"):
                self.shot("error-toast")
            t = s.get("time", 0)
            if s.get("isPlaying") and not ad and not s.get("isBuffering") and s.get("duration", 0) > 0:
                if last_t is not None and t > last_t + 0.4:
                    return s, saw_ad
                last_t = t if last_t is None else last_t
            if last_t is None or abs(t - (last_t or 0)) > 0.05 or ad:
                last_change = time.time()
            if time.time() - last_change > 45:
                break
            time.sleep(0.3)
        return None, saw_ad

    def run(self):
        self.launch()
        plays, distinct, transitions = [], set(), []
        system_routed = in_process = False
        while len(plays) < self.args.plays:
            t_start = time.time()
            s, saw_ad = self.wait_for_content()
            if not s:
                st = self.status()
                self.check(f"play {len(plays) + 1} starts", False, f"stalled on {st.get('videoID')} status={st.get('status')}")
                break
            plays.append({"videoID": s["videoID"], "title": s["title"], "playing": s.get("playingVideoID"), "ad": saw_ad,
                          "secondsToContent": round(time.time() - t_start, 1)})
            distinct.add(s["videoID"])
            self.log(f"play {len(plays)}: “{s['title']}” ({s.get('playingVideoID')}) after {time.time() - t_start:.1f}s"
                     + (" incl. ad" if saw_ad else ""))
            n = len(plays)
            if n == 1:
                media = s.get("media") or {}
                self.check("silent: page media volume is 0", media.get("volume") == 0, f"media={media}")
                if self.args.signed_in:
                    st = self.wait(10, "page account", lambda x: "page" in x) or self.status()
                    page = st.get("page") or {}
                    self.check("signed in: app session, signed-in player page (not anonymous)",
                               st.get("signedIn") and not st.get("anonymousPlayback") and page.get("loggedIn") is True,
                               f"signedIn={st.get('signedIn')} anonymous={st.get('anonymousPlayback')} page={page}")
                    self.check("Premium: the player page is a subscriber's", page.get("premium") is True, f"page={page}")
                time.sleep(2)
                self.check_now_playing("track 1", s)
                self.shot("playing-panel")
                send("surface:stage")
                time.sleep(2.5)
                self.shot("playing-stage")
                send("surface:window")
                time.sleep(1)
            if n == 2:
                # In-process MPRemoteCommandCenter dispatch (what media keys / Control Center trigger).
                send("remote:pause")
                p = self.wait(4, "remote pause", lambda x: x.get("status") == "paused")
                send("remote:play")
                q = self.wait(6, "remote play", lambda x: x.get("isPlaying"))
                in_process = bool(p and q)
                self.check("MPRemoteCommandCenter pause/play (in-process dispatch)", in_process)
                before = self.status().get("historyCount", 0)
                send("remote:next")
                r = self.wait(10, "remote next", lambda x: x.get("historyCount", 0) > before)
                self.check("MPRemoteCommandCenter next (in-process dispatch)", bool(r), (r or {}).get("title", ""))
                transitions.append(round(time.time() - t_start, 1))
                continue
            if n == 3:
                # A real MediaRemote command, addressed to this app's own player only.
                a = now_playing("send", "pause", BUNDLE)
                p = self.wait(5, "system pause", lambda x: x.get("status") == "paused")
                time.sleep(1)
                self.check_now_playing("paused", self.status())
                b = now_playing("send", "play", BUNDLE)
                q = self.wait(6, "system play", lambda x: x.get("isPlaying"))
                before = self.status().get("historyCount", 0)
                c = now_playing("send", "next", BUNDLE)
                r = self.wait(10, "system next", lambda x: x.get("historyCount", 0) > before)
                system_routed = bool(p and q and r)
                self.check("system remote commands pause/play/next reach the app", system_routed,
                           f"{a.get('error') or a.get('result')} / {b.get('error') or b.get('result')} / {c.get('error') or c.get('result')}")
                continue
            if n == 5:
                self.check_now_playing("track 5", s)
            if n >= self.args.plays:
                break
            before = s.get("historyCount", 0)
            send("seekEnd:4")
            r = self.wait(60, "advance", lambda x: x.get("historyCount", 0) > before or x.get("videoID") != s["videoID"])
            if not r:
                self.check(f"advance after play {n}", False, f"stuck: {self.status()}")
                break
            transitions.append(round(time.time() - t_start, 1))

        self.check(f"{self.args.plays} tracks played in a row without a stall", len(plays) >= self.args.plays,
                   f"{len(plays)} plays, {len(distinct)} distinct")
        if self.args.signed_in:
            ads = [p["title"] for p in plays if p["ad"]]
            self.check("no ads (Premium, signed-in playback)", not ads, f"{len(ads)} of {len(plays)} plays had an ad {ads}")
            self.check_reopen()
        st = self.status()
        failures = [c for c in st.get("commands", []) if not c.get("ok")]
        self.check("debug commands accepted", not failures, json.dumps(failures)[:200])
        self.measure_cpu()
        if self.args.signed_in:
            self.check_relaunch()
        self.report = {"plays": plays, "transitions": transitions, "results": self.results}

    def check_reopen(self):
        """Close the main window while playing, bring it back the Dock's way: same track, still playing, time moved on."""
        s0, _ = self.wait_for_content()
        if not s0:
            self.check("reopening the main window keeps playback", False, "nothing playing")
            return
        send("window:close")
        closed = self.wait(5, "window closed", lambda x: not x.get("mainWindowVisible"))
        time.sleep(2)
        send("window:reopen")
        reopened = self.wait(8, "window reopened", lambda x: x.get("mainWindowVisible"))
        time.sleep(3)
        self.restore_focus()
        s1 = self.status()
        ok = bool(closed and reopened) and s1.get("videoID") == s0.get("videoID") and s1.get("isPlaying") \
            and s1.get("time", 0) > s0.get("time", 0) + 2
        self.check("reopening the main window keeps playback (same track, still playing, time advancing)", ok,
                   f"“{s0.get('title')}” {s0.get('time', 0):.1f}s → “{s1.get('title')}” {s1.get('time', 0):.1f}s, "
                   f"playing={s1.get('isPlaying')} closed={bool(closed)} reopened={bool(reopened)}")

    def check_relaunch(self):
        """Quit (paused), relaunch without a launch track: the saved queue comes back at the same track and position."""
        before = self.status()
        self.quit_gracefully()
        self.launch(relaunch=True)
        after = self.wait(60, "queue restored", lambda x: x.get("videoID") and x.get("status") in ("paused", "playing"))
        after = after or self.status()
        drift = abs(after.get("time", 0) - before.get("time", 0))
        self.check("queue survives a relaunch (same track and position, paused)",
                   after.get("videoID") == before.get("videoID") and drift < 3 and after.get("status") == "paused",
                   f"before “{before.get('title')}” {before.get('time', 0):.1f}s ({before.get('historyCount')} played) → "
                   f"after “{after.get('title')}” {after.get('time', 0):.1f}s status={after.get('status')} "
                   f"upNext+autoplay={after.get('upNextCount', 0) + after.get('autoplayCount', 0)}")

    def measure_cpu(self):
        s = self.status()
        wc = s.get("webContentPID")
        pids = {"app": self.pid, "webContent": wc}
        def sample(label, seconds):
            a = {k: cpu_time(p) for k, p in pids.items() if p}
            time.sleep(seconds)
            b = {k: cpu_time(p) for k, p in pids.items() if p}
            pct = {k: round((b[k] - a[k]) / seconds * 100, 2) for k in a if a[k] is not None and b.get(k) is not None}
            self.log(f"CPU {label}: {pct}")
            return pct
        if s.get("ad") or not s.get("isPlaying"):
            self.wait_for_content()
        playing = sample("playing (panel)", 10)
        send("pause")
        time.sleep(8)  # the page freezes ~6 s into a pause
        paused = sample("paused", 20)
        self.check("paused: app and WebContent each under 1% CPU", all(v < 1.0 for v in paused.values()),
                   f"playing {playing}, paused {paused}, frozen={self.status().get('pageFrozen')}")
        self.cpu = {"playing": playing, "paused": paused}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--plays", type=int, default=10)
    ap.add_argument("--lang", default="en-US")
    ap.add_argument("--shots", default="", help="screenshot name prefix (e.g. playback-live-en)")
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--signed-in", action="store_true", help="the user's library, signed-in playback, relaunch + reopen checks")
    args = ap.parse_args()
    if not os.path.exists(EXE):
        sys.exit(f"error: {APP} not built (QT_VARIANT={VARIANT} Scripts/build-app.sh)")
    if args.signed_in:
        # Start from a clean queue (a saved one would restore paused and win over -qt.paused NO).
        saved = os.path.expanduser(f"~/Library/Application Support/{BUNDLE}/Playback/Queue.json")
        if os.path.exists(saved):
            os.remove(saved)
    run = Run(args)
    try:
        run.run()
    finally:
        run.quit()
    report = getattr(run, "report", {"results": run.results})
    report["cpu"] = getattr(run, "cpu", None)
    out = os.path.join(REPO, ".build", "playback-acceptance.json")
    with open(out, "w") as f:
        json.dump(report, f, indent=2, ensure_ascii=False)
    failed = [r for r in run.results if not r["ok"]]
    print(f"\n== {len(run.results) - len(failed)}/{len(run.results)} checks passed == ({out})")
    for r in run.results:
        print(("PASS  " if r["ok"] else "FAIL  ") + r["check"] + (f" — {r['detail']}" if r["detail"] else ""))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
