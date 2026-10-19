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
