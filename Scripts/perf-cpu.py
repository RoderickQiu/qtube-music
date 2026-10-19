#!/usr/bin/env python3
"""CPU of the bundled app (+ its WebContent process) in one scenario, averaged over a window.

    Scripts/perf-cpu.py <label> [--seconds 30] [--settle 8] [--sample] [launch args…]

    QT_VARIANT=perf Scripts/perf-cpu.py blur-stage -qt.surface stage -qt.stageBackground blur -qt.paused NO
    QT_VARIANT=perf Scripts/perf-cpu.py window-web -qt.engine web -qt.paused NO

Launches the variant's app in the background (`open -g -n`, mock catalog + mock lyrics unless given, on
$QT_SCREEN, default the built-in display), waits for the ready file, lets it settle, then reads `ps -o time` for the
app and the WebContent pid from the DEBUG status file at the start and end of the window. `--sample` also runs
`sample <pid> 10` into .build/perf-<label>.sample.txt; `--trace "Time Profiler"` records 10 s of that
Instruments template into .build/perf-<label>.trace; `--keep` leaves the app running.
The app is brought to the front for the measurement (clock-driven views pause while their window is covered) and
focus is handed back afterwards; `--background` measures it wherever `open -g` left it.
`--shot <name>` captures the main window after the settle (before measuring) into the main checkout's
screenshots/<name>.png (`$QT_SCREENSHOTS` overrides the folder). Prints one JSON line and appends it to .build/perf-cpu.jsonl.
Refuses to measure while another QTube Music instance runs (it would pollute Now Playing and CPU numbers).
"""
import json
import os
import subprocess
import sys
import tempfile
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def sh(*args):
    return subprocess.run(args, capture_output=True, text=True).stdout.strip()


def app_path():
    return sh(os.path.join(REPO, "Scripts", "build-app.sh"), "--print-path")


def cpu_time(pid):
    out = sh("ps", "-o", "time=", "-p", str(pid))
    if not out:
        return None
    total = 0.0
    for part in out.split(":"):
        total = total * 60 + float(part)
    return total


def screenshots_dir():
    if os.environ.get("QT_SCREENSHOTS"):
        return os.environ["QT_SCREENSHOTS"]
    first = sh("git", "-C", REPO, "worktree", "list", "--porcelain").splitlines()[0]
    return os.path.join(first.removeprefix("worktree "), "screenshots")


def capture(info, name):
    """The main window (by its number in the ready file) -> <main checkout>/screenshots/<name>.png."""
    number = next((w["number"] for w in info["windows"] if w["identifier"] == "qt.window.main"), None)
    if number is None:
        print("warning: no main window to capture", file=sys.stderr)
        return
    out = os.path.join(screenshots_dir(), f"{name}.png")
    subprocess.run(["screencapture", f"-l{number}", "-o", "-x", out])
    print(out, file=sys.stderr)


def main():
    argv = sys.argv[1:]
    if not argv:
        print(__doc__)
        return 2
    label, rest = argv[0], argv[1:]
    seconds, settle, do_sample, trace, keep, front, shot, args = 30.0, 8.0, False, None, False, True, None, []
    i = 0
    while i < len(rest):
        if rest[i] == "--seconds":
            seconds = float(rest[i + 1]); i += 2
        elif rest[i] == "--settle":
            settle = float(rest[i + 1]); i += 2
        elif rest[i] == "--sample":
            do_sample = True; i += 1
        elif rest[i] == "--trace":
            trace = rest[i + 1]; i += 2
        elif rest[i] == "--keep":
            keep = True; i += 1
        elif rest[i] == "--shot":
            shot = rest[i + 1]; i += 2
        elif rest[i] == "--background":
            front = False; i += 1
        else:
            args.append(rest[i]); i += 1

    app = app_path()
    exe = os.path.join(app, "Contents", "MacOS", "QTubeMusic")
    others = [l for l in sh("pgrep", "-fl", ".app/Contents/MacOS/QTubeMusic").splitlines() if exe not in l]
    if others:
        print("warning: other QTube instances are running:\n  " + "\n  ".join(others), file=sys.stderr)
    subprocess.run(["pkill", "-f", f"^{exe}"])
    time.sleep(0.5)

    ready = tempfile.mktemp(prefix="qt-perf-ready-", suffix=".json")
    status = tempfile.mktemp(prefix="qt-perf-status-", suffix=".json")
    launch = ["-ApplePersistenceIgnoreState", "YES", "-qt.screen", os.environ.get("QT_SCREEN", "Built-in"),
              "-qt.readyFile", ready, "-qt.playback.statusFile", status]
    if "-qt.catalog" not in args:
        launch += ["-qt.catalog", "mock"]
        if "-qt.lyrics.engine" not in args:
            launch += ["-qt.lyrics.engine", "mock"]
    subprocess.run(["open", "-g", "-n", app, "--args", *launch, *args])
    deadline = time.time() + 60
    while not (os.path.exists(ready) and os.path.getsize(ready) > 0):
        if time.time() > deadline:
            print("error: app did not become ready", file=sys.stderr)
            subprocess.run(["pkill", "-f", f"^{exe}"])
            return 1
        time.sleep(0.2)
    info = json.load(open(ready))
    pid = info["pid"]
    front_before = sh("osascript", "-e", 'tell application "System Events" to get bundle identifier of first '
                      'process whose frontmost is true')
    if front:
        # Clock-driven views stop while their window is covered (QTTickingView), so measure a window that's
        # actually on screen: bring the app forward, hand focus back at the end.
        sh("osascript", "-e", f'tell application id "{info["bundleID"]}" to activate')
    time.sleep(settle)

    def web_pid():
        try:
            return json.load(open(status)).get("webContentPID")
        except (OSError, ValueError):
            return None

    if shot:
        capture(info, shot)

    pids = {"app": pid, "webContent": web_pid()}
    a = {k: cpu_time(p) for k, p in pids.items() if p}
    t0 = time.time()
    if do_sample:
        out = os.path.join(REPO, ".build", f"perf-{label}.sample.txt")
        subprocess.run(["sample", str(pid), "10", "-file", out], capture_output=True)
    if trace:
        out = os.path.join(REPO, ".build", f"perf-{label}.trace")
        subprocess.run(["rm", "-rf", out])
        subprocess.run(["xcrun", "xctrace", "record", "--template", trace, "--attach", str(pid),
                        "--time-limit", "10s", "--output", out], capture_output=True)
    time.sleep(max(0.0, seconds - (time.time() - t0)))
    elapsed = time.time() - t0
    b = {k: cpu_time(p) for k, p in pids.items() if p}
    try:
        st = json.load(open(status))
    except (OSError, ValueError):
        st = {}
    result = {"label": label, "seconds": round(elapsed, 1),
              **{k: round((b[k] - a[k]) / elapsed * 100, 2) for k in a if a[k] is not None and b.get(k) is not None},
              "status": st.get("status"), "engine": st.get("engine"), "surface": st.get("surface"),
              "args": " ".join(args), "at": time.strftime("%Y-%m-%d %H:%M:%S")}
    if not keep:
        subprocess.run(["kill", str(pid)])
    if front and front_before:
        sh("osascript", "-e", f'tell application id "{front_before}" to activate')
    result["pid"] = pid
    for path in (ready, status):
        if os.path.exists(path):
            os.remove(path)
    line = json.dumps(result, ensure_ascii=False)
    print(line)
    with open(os.path.join(REPO, ".build", "perf-cpu.jsonl"), "a") as f:
        f.write(line + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
