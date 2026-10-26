#!/bin/zsh
# Opens the built app on a media file with a throwaway home folder (the real app data is not
# touched), waits, and captures only the app window.
#
#   Scripts/ui-capture.sh <media file> <output.png> [seconds to wait]
#
# Hooks (optional env): ALS_SELECT=<line> ALS_SEEK=<ms> ALS_TRANSLATE=1 ALS_MODE=dubbing
# APPEARANCE=light|dark (default: the system's). HOME_DIR=<dir> reuses a test home.
set -euo pipefail
cd "${0:A:h}/.."
MEDIA="${1:?media file}"
OUT="${2:?output png}"
WAIT="${3:-8}"
BIN="dist/Anime Localization Studio.app/Contents/MacOS/AnimeLocalizationStudio"
[[ -x "$BIN" ]] || { print -u2 "build first: Scripts/build-app.sh"; exit 1; }
HOME_DIR="${HOME_DIR:-$(mktemp -d)}"

pkill -f "$BIN" 2>/dev/null || true
CFFIXED_USER_HOME="$HOME_DIR" ALS_OPEN="$MEDIA" ALS_APPEARANCE="${APPEARANCE:-}" "$BIN" >/dev/null 2>&1 &
PID=$!
sleep "$WAIT"
ID="$(swift -e '
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerName as String] as? String) == "Anime Localization Studio" && (w[kCGWindowLayer as String] as? Int) == 0 {
    if let b = w[kCGWindowBounds as String] as? [String: Any], let h = b["Height"] as? Double, h > 300 { print(w[kCGWindowNumber as String]!); break }
}')"
[[ -n "$ID" ]] || { print -u2 "window not found"; kill $PID; exit 1; }
screencapture -x -o -l "$ID" "$OUT"
kill $PID 2>/dev/null || true
echo "$OUT (home: $HOME_DIR)"
