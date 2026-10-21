#!/usr/bin/env python3
"""Live reliability soak of real playback, in the bundled Debug app, silent (docs/prelaunch-implementation.md §3).

    QT_VARIANT=<name> Scripts/build-app.sh
    QT_VARIANT=<name> Scripts/playback-soak.py [--hours 3.5] [--album MPREb_…] [--anonymous] [--keep]

ONE AGENT AT A TIME. This talks to YouTube Music for hours; parallel live runs tripped Google's bot check before
(2026-10-19). The script takes a machine-wide lock and refuses to start while another soak, the acceptance script or
QTPlaybackLab runs. It stops at the first bot check.

Pace: real time, natural track ends only (no seeking to the end — fast skipping is what trips the bot check), about
15–20 tracks an hour. `-qt.catalog live` plays with the saved session (plays land in that account's history); with
`--anonymous` the player page is signed out, so ads are covered too. Media volume is pinned to 0 (scripted runs are
silent), the app launches in the background on the test display and never takes focus.

Scenarios, spread over the run:
  * an album that runs into radio (`--album <browse id>`: it starts on the album's last track, so Autoplay's radio
    has to continue the queue within minutes);
  * a 10-minute pause (sleep assertion released, page frozen; plays again on Play);
  * offline → online (the app's own offline path, `offline` / `online` debug commands; the Mac stays online);
  * Song⇄Video and back;
  * closing the main window and reopening it the Dock's way;
  * `pmset displaysleepnow` (display sleep is not system sleep: music must keep playing), woken after 3 min.

Logging: one JSON line every 5 s to .build/playback-soak.jsonl — the app's status file (state, track, queue counts,
wants playback, toast, last notice), the app's and WebContent's `pmset -g assertions` and memory, and every minute the
system's Now Playing client count. The summary goes to .build/playback-soak.json.

Pass:
  * zero silent stops (wanting music, not playing or loading for 30 s, and nothing said);
  * the next track playing within 10 s of each natural end (ads not counted);
  * radio continues (the queue never runs dry after the album);
  * exactly one Now Playing entry for the app, none from WebKit;
  * no `.loading` longer than 60 s;
  * the sleep assertion released while paused;
  * memory growth (app + WebContent) under 150 MB.
"""
import argparse
import fcntl
import importlib.util
import json
import os
import re
import statistics
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True   # the shared helpers below come from the acceptance script; no __pycache__ in Scripts/
_spec = importlib.util.spec_from_file_location("qt_acceptance", os.path.join(HERE, "playback-acceptance.py"))
acc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(acc)

REPO, APP, EXE, BUNDLE, SCREEN = acc.REPO, acc.APP, acc.EXE, acc.BUNDLE, acc.SCREEN
sh, send, now_playing, frontmost = acc.sh, acc.send, acc.now_playing, acc.frontmost
LOCK = "/tmp/com.roderickqiu.qtube.live-soak.lock"
BOT_CHECK = re.compile(r"check this connection|unusual traffic", re.I)


def rss_mb(pid):
    out = sh("ps", "-o", "rss=", "-p", str(pid)) if pid else ""
    return round(int(out) / 1024, 1) if out.strip().isdigit() else None


def sleep_assertions(pids):
    """`PreventUserIdleSystemSleep` assertions held by these pids (name per pid)."""
    out = sh("pmset", "-g", "assertions", timeout=10)
    held = {}
    for line in out.splitlines():
        m = re.search(r"pid (\d+)\(([^)]*)\): .*?(PreventUserIdleSystemSleep|PreventSystemSleep)\s+named: \"([^\"]*)\"", line)
        if m and int(m.group(1)) in pids:
            held.setdefault(int(m.group(1)), []).append(f"{m.group(3)}: {m.group(4)}")
    return held


class Soak:
    def __init__(self, args):
        self.args = args
        self.status_path = tempfile.mktemp(prefix="qt-soak-status-", suffix=".json")
        self.ready_path = tempfile.mktemp(prefix="qt-soak-ready-", suffix=".json")
        self.log_path = os.path.join(REPO, ".build", "playback-soak.jsonl")
        self.results = []
        self.events = []
        self.front_before = frontmost()
        self.pid = None
        self.t0 = time.time()
        self.bot_check = False
        # Running observations.
        self.idle_since = None
        self.loading_since = None
        self.loading_longest = 0.0
        self.silent_stops = []
        self.transitions = []
        self.pending_end = None
        self.np_counts = []
        self.paused_assertions = []
        self.memory = []
        self.last_toast = ""
        self.last_notice = ""
        self.ran_dry = []
        self.scenario = None

    # MARK: output

    def say(self, msg):
        print(f"{time.time() - self.t0:8.1f}  {msg}", flush=True)

    def check(self, name, ok, detail=""):
        self.results.append({"check": name, "ok": bool(ok), "detail": detail})
        self.say(f"{'PASS' if ok else 'FAIL'}  {name}" + (f" — {detail}" if detail else ""))

    def event(self, kind, **info):
        info.update(kind=kind, at=round(time.time() - self.t0, 1))
        self.events.append(info)
        self.say(f"{kind}: {json.dumps({k: v for k, v in info.items() if k not in ('kind', 'at')}, ensure_ascii=False)}")

    def status(self):
        try:
            with open(self.status_path) as f:
                return json.load(f)
        except (OSError, ValueError):
            return {}

    # MARK: launch / quit

    def launch(self):
        sh("pkill", "-f", f"^{EXE}")
        time.sleep(0.5)
        args = ["-ApplePersistenceIgnoreState", "YES", "-qt.screen", SCREEN, "-qt.readyFile", self.ready_path,
                "-qt.playback.statusFile", self.status_path, "-qt.lang", "en-US", "-qt.panelTab", "now-playing",
                "-qt.catalog", "live", "-qt.paused", "NO", "-qt.playback.persist", "NO"]
        if self.args.anonymous:
            args += ["-qt.playback.anonymous", "YES"]
        subprocess.run(["open", "-g", "-n", APP, "--args", *args], check=True)
        end = time.time() + 120
        while time.time() < end and not os.path.exists(self.ready_path):
            time.sleep(0.5)
        self.restore_focus()
        with open(self.ready_path) as f:
            ready = json.load(f)
        if "error" in ready:
            raise SystemExit(f"app refused to launch: {ready['error']}")
        self.pid = ready["pid"]
        self.say(f"launched pid {self.pid} ({BUNDLE}), {'anonymous' if self.args.anonymous else 'signed-in'} playback")

    def quit(self):
        if self.pid and not self.args.keep:
            sh("kill", str(self.pid))
            time.sleep(1.5)
            sh("kill", "-9", str(self.pid))
        self.restore_focus()

    def restore_focus(self):
        now = frontmost()
        if self.front_before and now != self.front_before and now.startswith("com.roderickqiu.qtube"):
            sh("osascript", "-e", f'tell application id "{self.front_before}" to activate')

    # MARK: watching

    def observe(self, s, prev):
        """One look at the status (every second): bot check, silent stops, loading, natural ends."""
        now = time.time()
        if BOT_CHECK.search(s.get("lastFailureMessage", "") + " " + s.get("toast", "")):
            self.bot_check = True
            self.event("bot-check", message=s.get("lastFailureMessage") or s.get("toast"))
            return
        if s.get("toast") and s.get("toast") != self.last_toast:
            self.event("toast", message=s["toast"])
        self.last_toast = s.get("toast", "")
        if s.get("lastNotice") and s["lastNotice"] != self.last_notice:
            self.event("notice", notice=s["lastNotice"])
            self.idle_since = None
        self.last_notice = s.get("lastNotice", "")

        status = s.get("status", "")
        # A silent stop: the listener wants music, nothing plays or loads, nothing was said (30 s; a scenario's own
        # pause sets wantsPlayback false).
        if s.get("wantsPlayback") and status not in ("playing", "loading") and not s.get("toast"):
            self.idle_since = self.idle_since or now
            if now - self.idle_since > 30:
                self.silent_stops.append({"at": round(now - self.t0), "status": status, "videoID": s.get("videoID"),
                                          "scenario": self.scenario})
                self.event("silent-stop", status=status, title=s.get("title"))
                self.idle_since = None
        else:
            self.idle_since = None
        if status == "loading" and s.get("networkAvailable", True):
            self.loading_since = self.loading_since or now
            self.loading_longest = max(self.loading_longest, now - self.loading_since)
        else:
            self.loading_since = None
        # A natural end: the track changes after its last seconds and history grows.
        if prev and s.get("videoID") != prev.get("videoID") and s.get("historyCount", 0) > prev.get("historyCount", 0) \
                and prev.get("duration", 0) > 0 and prev.get("time", 0) >= prev["duration"] - 6 and not self.scenario:
            self.pending_end = {"at": now, "from": prev.get("title"), "to": s.get("title"), "ad": False}
        if self.pending_end:
            if s.get("ad"):
                self.pending_end["ad"] = True
            elif s.get("isPlaying") and not s.get("isBuffering") and s.get("time", 0) > 0.5:
                gap = now - self.pending_end["at"]
                self.transitions.append({**self.pending_end, "seconds": round(gap, 1), "at": round(now - self.t0)})
                self.say(f"next track after {gap:.1f} s: “{self.pending_end['to']}”" + (" (ad)" if self.pending_end["ad"] else ""))
                self.pending_end = None
            elif now - self.pending_end["at"] > 120:
                self.transitions.append({**self.pending_end, "seconds": None, "at": round(now - self.t0)})
                self.pending_end = None
        # The queue running dry while listening (radio didn't continue).
        if s.get("wantsPlayback") and s.get("upNextCount", 0) + s.get("autoplayCount", 0) == 0 \
                and not s.get("fetchingAutoplay") and status == "ended":
            self.ran_dry.append(round(now - self.t0))

    def log_line(self, s, extra=None):
        wc = s.get("webContentPID")
        line = {"t": round(time.time() - self.t0, 1), "status": s.get("status"), "videoID": s.get("videoID"),
                "title": s.get("title"), "time": round(s.get("time", 0), 1), "duration": s.get("duration"),
                "wants": s.get("wantsPlayback"), "buffering": s.get("isBuffering"), "ad": bool(s.get("ad")),
                "history": s.get("historyCount"), "upNext": s.get("upNextCount"), "autoplay": s.get("autoplayCount"),
                "toast": s.get("toast"), "notice": s.get("lastNotice"), "frozen": s.get("pageFrozen"),
                "network": s.get("networkAvailable"), "scenario": self.scenario,
                "assertions": {str(k): v for k, v in sleep_assertions({p for p in (self.pid, wc) if p}).items()},
                "rssMB": {"app": rss_mb(self.pid), "webContent": rss_mb(wc)}}
        if extra:
            line.update(extra)
        mem = [v for v in line["rssMB"].values() if v]
        if mem:
            self.memory.append((time.time() - self.t0, sum(mem)))
        with open(self.log_path, "a") as f:
            f.write(json.dumps(line, ensure_ascii=False) + "\n")
        return line

    def watch(self, seconds):
        """Watches for `seconds` (1 s polls, a log line every 5 s, Now Playing every minute). False on a bot check."""
        end = time.time() + seconds
        prev = self.status()
        tick = 0
        while time.time() < end and not self.bot_check:
            time.sleep(1)
            s = self.status()
            if not s:
                continue
            self.observe(s, prev)
            prev = s
            tick += 1
            if tick % 5 == 0:
                extra = None
                if tick % 60 == 0:
                    clients = now_playing("clients").get("clients", [])
                    ours = len([c for c in clients if c.get("bundleIdentifier") == BUNDLE])
                    webkit = len([c for c in clients if c.get("parentApplicationBundleIdentifier") == BUNDLE])
                    self.np_counts.append((ours, webkit))
                    extra = {"nowPlayingClients": {"app": ours, "webkit": webkit}}
                self.log_line(s, extra)
        return not self.bot_check

    def wait_for(self, timeout, cond):
        end = time.time() + timeout
        while time.time() < end and not self.bot_check:
            s = self.status()
            if s and cond(s):
                return s
            time.sleep(0.5)
        return None

    # MARK: scenarios

    def scenario_start(self):
        if self.args.album:
            self.scenario = "album→radio"
            send(f"albumEnd:{self.args.album}")
            s = self.wait_for(60, lambda x: x.get("isPlaying"))
            self.event("album", title=(s or {}).get("title"), autoplay=(s or {}).get("autoplayCount"))
            self.scenario = None
        else:
            self.say("no --album: the radio scenario relies on the launch's own queue")
        self.album_history = self.status().get("historyCount", 0)

    def scenario_pause(self):
        self.scenario = "10-minute pause"
        send("pause")
        self.wait_for(10, lambda x: x.get("status") == "paused")
        time.sleep(30)
        s = self.status()
        held = sleep_assertions({p for p in (self.pid, s.get("webContentPID")) if p})
        self.paused_assertions.append(held)
        self.event("paused", frozen=s.get("pageFrozen"), assertions=held)
        ok = self.watch(570)
        self.check("10-minute pause: no sleep assertion held while paused", not held, json.dumps(held))
        if not ok:
            return
        send("play")
        s = self.wait_for(15, lambda x: x.get("isPlaying") and not x.get("isBuffering"))
        self.check("10-minute pause: plays again within 15 s of Play", bool(s), (s or self.status()).get("status", ""))
        self.scenario = None

    def scenario_offline(self):
        self.scenario = "offline → online"
        send("offline")
        ok = self.watch(120)
        send("online")
        if not ok:
            return
        s = self.wait_for(90, lambda x: x.get("isPlaying") and not x.get("isBuffering"))
        self.check("offline → online: playing again within 90 s", bool(s), (s or self.status()).get("status", ""))
        self.scenario = None

    def scenario_song_video(self):
        self.scenario = "Song⇄Video"
        send("mode:video")
        ok = self.watch(60)
        send("mode:song")
        if not ok:
            return
        s = self.wait_for(30, lambda x: x.get("mode") == "song" and x.get("isPlaying"))
        self.check("Song⇄Video: back on the song, playing", bool(s), (s or self.status()).get("mode", ""))
        self.scenario = None

    def scenario_window(self):
        self.scenario = "window close/reopen"
        before = self.status()
        send("window:close")
        ok = self.watch(30)
        send("window:reopen")
        self.restore_focus()
        if not ok:
            return
        s = self.wait_for(10, lambda x: x.get("mainWindowVisible"))
        after = self.status()
        self.check("window close/reopen: still playing, time moved on",
                   bool(s) and after.get("isPlaying") and (after.get("videoID") != before.get("videoID")
                                                           or after.get("time", 0) > before.get("time", 0) + 20),
                   f"{before.get('time', 0):.0f}s → {after.get('time', 0):.0f}s")
        self.scenario = None

    def scenario_display_sleep(self):
        self.scenario = "display sleep"
        before = self.status()
        sh("pmset", "displaysleepnow")
        ok = self.watch(180)
        sh("caffeinate", "-u", "-t", "2")
        if not ok:
            return
        after = self.status()
        moved = after.get("historyCount", 0) > before.get("historyCount", 0) or after.get("time", 0) > before.get("time", 0) + 60
        self.check("display sleep: music played on", after.get("isPlaying") and moved,
                   f"history {before.get('historyCount')} → {after.get('historyCount')}")
        self.scenario = None

    # MARK: run

    def run(self):
        os.makedirs(os.path.dirname(self.log_path), exist_ok=True)
        open(self.log_path, "w").close()
        self.launch()
        if not self.wait_for(120, lambda x: x.get("isPlaying") or x.get("status") in ("paused", "loading")):
            self.check("launch: something to play", False, json.dumps(self.status())[:200])
            return
        self.scenario_start()
        total = self.args.hours * 3600
        plan = [(0.10, self.scenario_song_video), (0.22, self.scenario_pause), (0.40, self.scenario_offline),
                (0.55, self.scenario_window), (0.70, self.scenario_display_sleep)]
        for fraction, scenario in plan:
            wait = self.t0 + fraction * total - time.time()
            if wait > 0 and not self.watch(wait):
                break
            scenario()
            if self.bot_check:
                break
        if not self.bot_check:
            self.watch(max(0, self.t0 + total - time.time()))
        self.summarize()

    def summarize(self):
        s = self.status()
        self.check("no bot check (the run stops at the first one)", not self.bot_check)
        self.check("zero silent stops", not self.silent_stops, json.dumps(self.silent_stops)[:300])
        timed = [t for t in self.transitions if not t["ad"]]
        slow = [t for t in timed if t["seconds"] is None or t["seconds"] > 10]
        self.check("next track within 10 s of each natural end (ads not counted)", timed and not slow,
                   f"{len(timed)} ends, slowest {max((t['seconds'] or 999) for t in timed) if timed else '-'} s, slow: {slow[:3]}")
        played = s.get("historyCount", 0) - getattr(self, "album_history", 0)
        self.check("radio continues (the queue never ran dry)", not self.ran_dry and played > 3,
                   f"{played} tracks after the start, ran dry at {self.ran_dry[:5]}")
        bad_np = [c for c in self.np_counts if c != (1, 0)]
        self.check("one Now Playing entry, none from WebKit", self.np_counts and not bad_np,
                   f"{len(self.np_counts)} readings, off: {bad_np[:5]}")
        self.check("no .loading longer than 60 s", self.loading_longest <= 60, f"longest {self.loading_longest:.0f} s")
        if self.memory:
            early = [m for t, m in self.memory if t < 900] or [self.memory[0][1]]
            late = [m for t, m in self.memory if t > self.memory[-1][0] - 900] or [self.memory[-1][1]]
            growth = statistics.median(late) - statistics.median(early)
            self.check("memory growth (app + WebContent) under 150 MB", growth < 150,
                       f"{statistics.median(early):.0f} → {statistics.median(late):.0f} MB")
        hours = (time.time() - self.t0) / 3600
        self.say(f"{len(timed)} natural ends in {hours:.2f} h ({len(timed) / max(hours, 0.01):.1f}/h)")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--hours", type=float, default=3.5)
    ap.add_argument("--album", default="", help="album browse id (MPREb_…) to start from its last track")
    ap.add_argument("--anonymous", action="store_true", help="signed-out player page (ads included)")
    ap.add_argument("--keep", action="store_true", help="leave the app running afterwards")
    args = ap.parse_args()
    if not os.path.exists(EXE):
        sys.exit(f"error: {APP} not built (QT_VARIANT=… Scripts/build-app.sh)")
    lock = open(LOCK, "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        sys.exit("error: another live soak is running (one live agent at a time)")
    for other in ("playback-acceptance.py", "native-acceptance.py", "QTPlaybackLab"):
        if sh("pgrep", "-f", other):
            sys.exit(f"error: {other} is running — one live run at a time (YouTube's bot check)")
    soak = Soak(args)
    try:
        soak.run()
    finally:
        soak.quit()
    out = os.path.join(REPO, ".build", "playback-soak.json")
    with open(out, "w") as f:
        json.dump({"results": soak.results, "events": soak.events, "transitions": soak.transitions,
                   "silentStops": soak.silent_stops, "loadingLongest": soak.loading_longest}, f, indent=2, ensure_ascii=False)
    failed = [r for r in soak.results if not r["ok"]]
    print(f"\n== {len(soak.results) - len(failed)}/{len(soak.results)} checks passed == ({out}, log {soak.log_path})")
    for r in soak.results:
        print(("PASS  " if r["ok"] else "FAIL  ") + r["check"] + (f" — {r['detail']}" if r["detail"] else ""))
    sys.exit(1 if failed or soak.bot_check else 0)


if __name__ == "__main__":
    main()
