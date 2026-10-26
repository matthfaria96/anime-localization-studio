#!/bin/zsh
# Builds "dist/Anime Localization Studio.app" with SwiftPM (no Xcode project needed).
#
#   Scripts/build-app.sh [release|debug]
#
# Environment:
#   SIGN_IDENTITY   codesign identity; default is an ad-hoc signature (-).
#   SKIP_TESTS=1    skip `swift test` before packaging.
set -euo pipefail
cd "${0:A:h}/.."

# The Command Line Tools cannot expand the SwiftUI / FoundationModels macros; use Xcode.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

CONFIG="${1:-release}"
NAME="Anime Localization Studio"
EXE="AnimeLocalizationStudio"
DIST="dist"
APP="$DIST/$NAME.app"
WORK="build"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

fail() { print -u2 "error: $*"; exit 1; }

VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')" || true
[[ "$VERSION" =~ '^[0-9]+(\.[0-9]+){0,2}$' ]] || VERSION="0.1.0"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

if [[ "${SKIP_TESTS:-0}" != 1 ]]; then
  swift test
fi
swift build -c "$CONFIG" --arch arm64
BIN_DIR="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$WORK"
cp "$BIN_DIR/$EXE" "$APP/Contents/MacOS/$EXE"

# SwiftPM stamps the deployment target as the SDK version; without the real SDK version
# macOS runs the app in compatibility appearance (no Liquid Glass).
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
MIN_OS="$(sed -nE 's/.*\.macOS\("([0-9.]+)"\).*/\1/p' Package.swift | head -1)"
[[ -n "$MIN_OS" ]] || fail "could not read the macOS platform from Package.swift"
vtool -set-build-version macos "$MIN_OS" "$SDK_VERSION" -replace -output "$APP/Contents/MacOS/$EXE" "$APP/Contents/MacOS/$EXE"

PLIST="$APP/Contents/Info.plist"
cp Resources/Info.plist "$PLIST"
PB=/usr/libexec/PlistBuddy
$PB -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
$PB -c "Set :CFBundleVersion $BUILD" "$PLIST"
$PB -c "Set :LSMinimumSystemVersion $MIN_OS" "$PLIST"

# Resource bundle content (asset catalog, .lproj) moves into the app, where Bundle.main and
# NSAccentColorName look for it.
RES_BUNDLE="$BIN_DIR/${EXE}_${EXE}.bundle"
[[ -d "$RES_BUNDLE" ]] || fail "resource bundle not found: $RES_BUNDLE"
for lproj in "$RES_BUNDLE"/**/*.lproj(N/); do cp -R "$lproj" "$APP/Contents/Resources/"; done
CAR=("$RES_BUNDLE"/**/Assets.car(N))
[[ -n "${CAR[1]:-}" ]] || fail "Assets.car was not built"
cp "${CAR[1]}" "$APP/Contents/Resources/Assets.car"
ls "$APP/Contents/Resources"/pt-BR.lproj/Localizable.strings >/dev/null 2>&1 || ls "$APP/Contents/Resources"/pt-br.lproj/Localizable.strings >/dev/null \
  || fail "pt-BR localization was not copied"

if [[ ! -f "$WORK/AppIcon.icns" || Scripts/make-icon.swift -nt "$WORK/AppIcon.icns" ]]; then
  ICONSET="$WORK/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  swift Scripts/make-icon.swift "$WORK/icon-1024.png"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$WORK/icon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$WORK/icon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$WORK/AppIcon.icns"
fi
cp "$WORK/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

mkdir -p "$APP/Contents/Resources/Licenses"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/Licenses/THIRD_PARTY_NOTICES.md"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --deep --sign - "$APP"
else
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP ($VERSION build $BUILD)"
