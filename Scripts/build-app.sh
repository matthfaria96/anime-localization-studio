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
  # A test copies the MLX kernels next to its binary and removes them; clear a leftover so signing never fails.
  rm -f .build/out/Products/*/*.xctest/Contents/MacOS/mlx.metallib(N)
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
# Resource bundles of the Swift packages (MLX's GPU kernels, swift-transformers…): MLX and
# Bundle.module look for them in Contents/Resources.
for bundle in "$BIN_DIR"/*.bundle(N/); do
  [[ "$bundle" == "$RES_BUNDLE" ]] || cp -R "$bundle" "$APP/Contents/Resources/"
done
[[ -f "$APP/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ]] \
  || fail "MLX kernels (default.metallib) missing: install the Metal Toolchain (xcodebuild -downloadComponent MetalToolchain)"
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

# libass (ISC) and its dependencies come from Homebrew; copy every non-system dylib the
# executable needs into Contents/Frameworks and point the load commands there, so the app
# runs on Macs without Homebrew.
FW="$APP/Contents/Frameworks"
mkdir -p "$FW"
bundle_deps() {
  # $1: binary to fix, $2: where it came from (to resolve its @rpath/@loader_path references)
  local target="$1" origin="${2:-$1}" dep name source
  for dep in $(otool -L "$target" | awk 'NR>1 {print $1}'); do
    case "$dep" in
      /opt/homebrew/*|/usr/local/*) source="$dep" ;;
      @rpath/*|@loader_path/*) source="${origin:A:h}/${dep:t}"; [[ -f "$source" ]] || continue ;;
      *) continue ;;
    esac
    name="${dep:t}"
    [[ "$name" == "${target:t}" ]] && continue
    if [[ ! -f "$FW/$name" ]]; then
      cp -L "$source" "$FW/$name"
      chmod u+w "$FW/$name"
      install_name_tool -id "@rpath/$name" "$FW/$name" 2>/dev/null
      bundle_deps "$FW/$name" "${source:A}"
    fi
    [[ "$dep" == "@rpath/$name" ]] || install_name_tool -change "$dep" "@rpath/$name" "$target" 2>/dev/null
  done
}
bundle_deps "$APP/Contents/MacOS/$EXE"
for lib in "$FW"/*.dylib(N); do
  otool -l "$lib" | grep -q "@loader_path" || install_name_tool -add_rpath "@loader_path" "$lib" 2>/dev/null || true
done
otool -l "$APP/Contents/MacOS/$EXE" | grep -q "@executable_path/../Frameworks" \
  || install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$EXE"
if otool -L "$APP/Contents/MacOS/$EXE" "$FW"/*.dylib(N) | grep -E "^\s+/(opt/homebrew|usr/local)/" ; then
  fail "a bundled library still points outside the app"
fi

mkdir -p "$APP/Contents/Resources/Licenses"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/Licenses/THIRD_PARTY_NOTICES.md"
cp LICENSE "$APP/Contents/Resources/Licenses/AnimeLocalizationStudio-GPL-3.0.txt"
# License texts of the bundled libraries, taken from their Homebrew kegs.
for pkg in libass freetype fribidi harfbuzz libunibreak gettext pcre2 graphite2 libpng brotli; do
  keg="$(brew --prefix "$pkg" 2>/dev/null)" || continue
  for f in "$keg"/(COPYING|LICENSE|LICENCE|LICENSE.TXT|LICENCE.md)(N); do cp "$f" "$APP/Contents/Resources/Licenses/$pkg-${f:t}"; done
done
# Swift packages linked into the executable (FluidAudio, Apache-2.0).
for f in .build/checkouts/FluidAudio/(LICENSE|NOTICE)*(N); do cp "$f" "$APP/Contents/Resources/Licenses/FluidAudio-${f:t}"; done
# speech-swift (Apache-2.0) with Chatterbox Multilingual (MIT model), MLX (MIT), swift-transformers (Apache-2.0).
for pkg in speech-swift mlx-swift swift-transformers swift-crypto swift-jinja; do
  for f in .build/checkouts/$pkg/(LICENSE|LICENSE.txt|LICENSE.md|NOTICE)(N); do cp "$f" "$APP/Contents/Resources/Licenses/$pkg-${f:t}"; done
done
# Code FluidAudio ports from other projects (fastcluster, VBx clustering used by diarization, …).
[[ -d .build/checkouts/FluidAudio/ThirdPartyLicenses ]] && cp -R .build/checkouts/FluidAudio/ThirdPartyLicenses "$APP/Contents/Resources/Licenses/FluidAudio-ThirdPartyLicenses"
# glib ships no license file in its keg; it is LGPL-2.1-or-later, the same text as FriBidi's COPYING.
fribidi_copying="$(brew --prefix fribidi 2>/dev/null)/COPYING"
[[ -f "$fribidi_copying" ]] && cp "$fribidi_copying" "$APP/Contents/Resources/Licenses/glib-LGPL-2.1.txt"

for lib in "$FW"/*.dylib(N); do codesign --force --sign "$SIGN_IDENTITY" "$lib"; done
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --deep --sign - "$APP"
else
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP ($VERSION build $BUILD)"
