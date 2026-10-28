#!/bin/zsh
# Opens the built app on a media file with a throwaway home folder (the real app data is not
# touched), waits, and captures only the app window.
#
#   Scripts/ui-capture.sh <media file, or - for the start screen> <output.png> [seconds to wait]
#
# Hooks (optional env): ALS_SETTINGS=<tab> ALS_SELECT=<line> ALS_SEEK=<ms> ALS_TRANSLATE=1 ALS_MODE=subtitles|dubbing ALS_TASK=edit|translate ALS_SIZE=WxH
# APPEARANCE=light|dark (default: the system's). LANGUAGE=en|pt-BR (default: the system's). HOME_DIR=<dir> reuses a test home.
set -euo pipefail
cd "${0:A:h}/.."
MEDIA="${1:?media file}"
OUT="${2:?output png}"
WAIT="${3:-8}"
BIN="dist/Anime Localization Studio.app/Contents/MacOS/AnimeLocalizationStudio"
[[ -x "$BIN" ]] || { print -u2 "build first: Scripts/build-app.sh"; exit 1; }
HOME_DIR="${HOME_DIR:-$(mktemp -d)}"

ARGS=()
[[ -n "${LANGUAGE:-}" ]] && ARGS=(-AppleLanguages "($LANGUAGE)" -AppleLocale "${LANGUAGE/-/_}")
[[ "$MEDIA" == "-" ]] || export ALS_OPEN="$MEDIA"
CFFIXED_USER_HOME="$HOME_DIR" ALS_APPEARANCE="${APPEARANCE:-}" "$BIN" "${ARGS[@]}" >/dev/null 2>&1 &
PID=$!
list_windows() {
  swift -e '
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
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
# Windows that cannot be captured (hidden helpers) are skipped. The largest one is the main
# window; the others (sheets, panels) are saved as OUT-2.png, OUT-3.png…
SHOTS=()
for id in "${IDS[@]}"; do
  shot="${OUT:r}.$id.png"
  screencapture -x -o -l "$id" "$shot" 2>/dev/null && [[ -s "$shot" ]] && SHOTS+=("$shot")
done
[[ ${#SHOTS} -gt 0 ]] || { print -u2 "no window could be captured"; kill $PID; exit 1; }
SORTED=(${(f)"$(for f in "${SHOTS[@]}"; do print "$(sips -g pixelWidth "$f" | awk '/pixelWidth/{print $2}') $f"; done | sort -rn | cut -d' ' -f2-)"})
mv "${SORTED[1]}" "$OUT"
n=2
for f in "${SORTED[@]:1}"; do mv "$f" "${OUT:r}-$n.png"; n=$((n + 1)); done
kill $PID 2>/dev/null || true
echo "$OUT (home: $HOME_DIR)"
