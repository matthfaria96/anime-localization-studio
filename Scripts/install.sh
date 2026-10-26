#!/bin/zsh
# Builds (with tests) and installs "Anime Localization Studio.app" into /Applications.
# A running copy is asked to quit first, so it never runs from a half-replaced bundle.
#
#   Scripts/install.sh          # tests + build + install
#   SKIP_TESTS=1 Scripts/install.sh
set -euo pipefail
cd "${0:A:h}/.."

./Scripts/build-app.sh release
APP="dist/Anime Localization Studio.app"
DEST="/Applications/Anime Localization Studio.app"
BUNDLE_ID="com.witchmymac.animelocalizationstudio"

if pgrep -f "$DEST/Contents/MacOS/" >/dev/null; then
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in {1..20}; do pgrep -f "$DEST/Contents/MacOS/" >/dev/null || break; sleep 0.5; done
fi

STAGE="$(mktemp -d)/Anime Localization Studio.app"
ditto "$APP" "$STAGE"
rm -rf "$DEST"
mv "$STAGE" "$DEST"
codesign --verify --strict "$DEST"
echo "Installed $DEST ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist"))"
