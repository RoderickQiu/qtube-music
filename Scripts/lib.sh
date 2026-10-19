# Shared helpers for Scripts/*.sh (source it). Works from the main checkout and from git worktrees.
QT_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The main checkout holds git-ignored inputs (design/prototype/data.js + assets, Generated/, screenshots/).
QT_MAIN="$(git -C "$QT_REPO" worktree list --porcelain | head -1 | sed 's/^worktree //')"
QT_SCREENSHOTS="$QT_MAIN/screenshots"
QT_TOOLS="$QT_REPO/.build/qt-tools"

qt_variant_name() { echo "QTube Music${QT_VARIANT:+ $QT_VARIANT}"; }
qt_bundle_id() { echo "com.roderickqiu.qtube${QT_VARIANT:+.dev-$QT_VARIANT}"; }
qt_app_path() { echo "$QT_REPO/.build/apps/$(qt_variant_name).app"; }

# qt_tool <name> → path of Scripts/tools/<name>.swift compiled into .build/qt-tools (rebuilt when the source changes).
qt_tool() {
  local src="$QT_REPO/Scripts/tools/$1.swift" bin="$QT_TOOLS/$1"
  mkdir -p "$QT_TOOLS"
  if [[ ! -x "$bin" || "$src" -nt "$bin" ]]; then
    xcrun swiftc -O -swift-version 5 -o "$bin" "$src" >&2 || return 1
  fi
  echo "$bin"
}

qt_frontmost_bundle() {
  osascript -e 'tell application "System Events" to get bundle identifier of first process whose frontmost is true' 2>/dev/null
}

# qt_screen → the display dev runs go on: $QT_SCREEN if set (it must be connected), else the external test display
# (U270CA) when it is connected, else the built-in display. Fails with a message when $QT_SCREEN isn't connected;
# a DEBUG app refuses such a launch too rather than putting its windows on another display.
qt_screen() {
  local tool
  tool="$(qt_tool qt-window-id)" || return 1
  if [[ -n "${QT_SCREEN:-}" ]]; then
    if ! "$tool" --display-bounds "$QT_SCREEN" >/dev/null; then
      echo "error: display '$QT_SCREEN' (QT_SCREEN) is not connected; connected: $("$tool" --screens | paste -sd, -)" >&2
      return 1
    fi
    echo "$QT_SCREEN"
  else
    "$tool" --default-screen U270CA || { echo "error: no display found" >&2; return 1; }
  fi
}

# qt_ready_error <ready file> → prints the app's refusal (e.g. screenMissing) and returns 0 if the file holds one.
qt_ready_error() {
  python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
if "error" in d:
    print("error: app refused to launch: %s (%s; connected: %s)" % (d["error"], d.get("screen", ""), ", ".join(d.get("screens", []))))
    sys.exit(0)
sys.exit(1)' "$1" 2>/dev/null
}

# qt_launch_args <arg>… → sets the array QT_ARGS to the launch arguments, checked so a typo fails at once instead of
# after the ready-file timeout. An argument that arrived as one string ("-qt.surface stage -qt.paused YES", an
# unsplit shell variable) is split into words (with a note). Then every argument must be a `-key value` pair: a key
# is `-name` (letters, digits, '.', '_', '-'), and its value must be there and must not itself look like a `-qt.` key.
# Values may contain spaces (-qt.live.open "album:Some Title"). Returns 2 with a message otherwise.
qt_launch_args() {
  QT_ARGS=()
  local a w
  for a in "$@"; do
    if [[ "$a" == -* && "$a" =~ [[:space:]] ]]; then
      echo "note: splitting one-string launch arguments '$a'" >&2
      local words=()
      # Shell-word split without evaluating anything (quotes honoured; no globbing, no expansion).
      while IFS= read -r -d '' w; do words+=("$w"); done < <(python3 -c 'import shlex,sys
for w in shlex.split(sys.argv[1]): sys.stdout.write(w + "\0")' "$a")
      [[ ${#words[@]} -gt 0 ]] || { echo "error: can't split launch arguments '$a'" >&2; return 2; }
      QT_ARGS+=("${words[@]}")
    else
      QT_ARGS+=("$a")
    fi
  done
  local i=0 n=${#QT_ARGS[@]} key value
  while (( i < n )); do
    key="${QT_ARGS[$i]}"
    if [[ ! "$key" =~ ^-[A-Za-z][A-Za-z0-9._-]*$ ]]; then
      echo "error: launch argument '$key' is not a -key (launch arguments are -key value pairs, e.g. -qt.surface stage)" >&2
      return 2
    fi
    if (( i + 1 >= n )); then
      echo "error: launch argument $key has no value (e.g. $key YES)" >&2
      return 2
    fi
    value="${QT_ARGS[$((i + 1))]}"
    if [[ "$value" =~ ^-qt\.[A-Za-z] ]]; then
      echo "error: launch argument $key has no value (the next argument is the key $value)" >&2
      return 2
    fi
    i=$((i + 2))
  done
}

# qt_wait_ready <ready file> <executable path> <timeout s> → waits for the app's ready file. Fails early (status 1,
# with a message) when the app quits or crashes before writing it, instead of waiting out the whole timeout.
qt_wait_ready() {
  local ready="$1" exe="$2" timeout="$3" started gone=0
  started=$(date +%s)
  until [[ -s "$ready" ]]; do
    if (( $(date +%s) - started > timeout )); then echo "error: app did not become ready within $timeout s" >&2; return 1; fi
    if pgrep -f "^$exe" >/dev/null; then
      gone=0
    elif (( $(date +%s) - started >= 3 )); then
      # Not running 3 s after `open` (or gone since) for a whole second: it quit or crashed.
      gone=$((gone + 1))
      if (( gone >= 10 )); then
        [[ -s "$ready" ]] && return 0
        echo "error: the app quit before it was ready (crashed, or refused its launch arguments; see Console)" >&2
        return 1
      fi
    fi
    sleep 0.1
  done
}
