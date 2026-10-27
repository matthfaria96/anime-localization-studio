#!/bin/zsh
# Opens the built app on a media file with a throwaway home folder (the real app data is not
# touched), waits, and captures only the app window.
#
#   Scripts/ui-capture.sh <media file> <output.png> [seconds to wait]
#
# Hooks (optional env): ALS_SELECT=<line> ALS_SEEK=<ms> ALS_TRANSLATE=1 ALS_MODE=subtitles|dubbing ALS_TASK=edit|translate ALS_SIZE=WxH
# APPEARANCE=light|dark (default: the system's). HOME_DIR=<dir> reuses a test home.
set -euo pipefail
cd "${0:A:h}/.."
MEDIA="${1:?media file}"
OUT="${2:?output png}"
WAIT="${3:-8}"
BIN="dist/Anime Localization Studio.app/Contents/MacOS/AnimeLocalizationStudio"
[[ -x "$BIN" ]] || { print -u2 "build first: Scripts/build-app.sh"; exit 1; }
HOME_DIR="${HOME_DIR:-$(mktemp -d)}"

CFFIXED_USER_HOME="$HOME_DIR" ALS_OPEN="$MEDIA" ALS_APPEARANCE="${APPEARANCE:-}" "$BIN" >/dev/null 2>&1 &
PID=$!
list_windows() {
  swift -e '
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
// Only the windows of the copy this script launched, never the app the user has open.
for w in list where (w[kCGWindowOwnerPID as String] as? Int) == Int(CommandLine.arguments[1]) && (w[kCGWindowLayer as String] as? Int) == 0 {
    if let b = w[kCGWindowBounds as String] as? [String: Any], let h = b["Height"] as? Double, h > 200 { print(w[kCGWindowNumber as String]!) }
}' "$PID"
}
# Wait for the window to appear (launch time varies), then give the content WAIT seconds.
for _ in {1..30}; do [[ -n "$(list_windows)" ]] && break; sleep 1; done
sleep "$WAIT"
IDS=(${(f)"$(list_windows)"})
[[ ${#IDS} -gt 0 ]] || { print -u2 "window not found"; kill $PID; exit 1; }
screencapture -x -o -l "${IDS[-1]}" "$OUT"
# Sheets and panels are separate windows: save them as OUT-2.png, OUT-3.png…
n=2
for id in "${IDS[@]:0:-1}"; do screencapture -x -o -l "$id" "${OUT:r}-$n.png"; n=$((n + 1)); done
kill $PID 2>/dev/null || true
echo "$OUT (home: $HOME_DIR)"
