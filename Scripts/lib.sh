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
