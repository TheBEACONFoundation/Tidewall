#!/bin/bash
# Builds build/Tidewall.app.
#
#   Scripts/build-app.sh              universal (Apple silicon + Intel) release build
#   Scripts/build-app.sh debug        native-architecture debug build
#
# Environment:
#   VERSION         marketing version (default: latest git tag without "v", else Info.plist)
#   SIGN_IDENTITY   e.g. "Developer ID Application: Jane Doe (TEAMID)". Signs with the
#                   hardened runtime for notarization. Without it the app is ad-hoc signed,
#                   which runs locally but is blocked by Gatekeeper once downloaded.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/Tidewall.app"
PLIST_SRC="Resources/Info.plist"

# SwiftUI's macros ship with Xcode, not with the standalone Command Line Tools.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if [[ -z "${VERSION:-}" ]]; then
    VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
    [[ -z "$VERSION" ]] && VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST_SRC")"
fi
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

mkdir -p .build/tools build

# Generated resources are committed; these only run if they were deleted.
if [[ ! -f Resources/AppIcon.icns ]]; then
    echo "==> Rendering app icon"
    swiftc -O -target arm64-apple-macos15 Scripts/make-icon.swift -o .build/tools/make-icon
    ICONSET=.build/tools/AppIcon.iconset
    rm -rf "$ICONSET" && mkdir -p "$ICONSET"
    .build/tools/make-icon .build/tools/icon-1024.png >/dev/null
    for s in 16 32 128 256 512; do
        sips -z $s $s .build/tools/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        sips -z $((s*2)) $((s*2)) .build/tools/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi
if [[ ! -f Resources/Aurora.mov ]]; then
    echo "==> Rendering sample wallpaper"
    swiftc -O -target arm64-apple-macos15 Scripts/make-sample.swift -o .build/tools/make-sample
    .build/tools/make-sample Resources/Aurora.mov | tail -1
fi

if [[ "$CONFIG" == "release" ]]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
else
    ARCH_FLAGS=()
fi

echo "==> Compiling Tidewall $VERSION ($BUILD_NUMBER), $CONFIG"
swift build -c "$CONFIG" "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}"
BIN="$(swift build -c "$CONFIG" "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}" --show-bin-path)/Tidewall"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Tidewall"
cp "$PLIST_SRC" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/Aurora.mov "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    echo "==> Signing with $SIGN_IDENTITY"
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
    echo "==> Ad-hoc signing (set SIGN_IDENTITY to sign for distribution)"
    codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"

echo "==> Built $APP ($(lipo -archs "$APP/Contents/MacOS/Tidewall"))"
