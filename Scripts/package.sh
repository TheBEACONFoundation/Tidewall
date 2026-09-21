#!/bin/bash
# Builds a release and packages it for distribution into dist/:
#   Tidewall-<version>.dmg, Tidewall-<version>.zip and SHA256SUMS.txt
#
# Environment (all optional):
#   VERSION         see build-app.sh
#   SIGN_IDENTITY   Developer ID Application identity; also signs the DMG
#   NOTARY_PROFILE  notarytool keychain profile (xcrun notarytool store-credentials).
#                   Requires SIGN_IDENTITY. Notarizes and staples the app and DMG.
#   NOTARY_KEYCHAIN keychain holding that profile, if not in the default search list
set -euo pipefail
cd "$(dirname "$0")/.."

Scripts/build-app.sh release

APP="build/Tidewall.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="dist/Tidewall-$VERSION.dmg"
ZIP="dist/Tidewall-$VERSION.zip"

rm -rf dist && mkdir -p dist

notarize() {
    echo "==> Notarizing $(basename "$1")"
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" ${NOTARY_KEYCHAIN:+--keychain "$NOTARY_KEYCHAIN"} --wait
}

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    [[ -z "${SIGN_IDENTITY:-}" ]] && { echo "NOTARY_PROFILE requires SIGN_IDENTITY" >&2; exit 1; }
    ditto -c -k --keepParent "$APP" build/notarize.zip
    notarize build/notarize.zip
    xcrun stapler staple "$APP"
    rm build/notarize.zip
fi

echo "==> Creating $ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Creating $DMG"
STAGING="build/dmg"
rm -rf "$STAGING" && mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -quiet -volname "Tidewall" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGING"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    notarize "$DMG"
    xcrun stapler staple "$DMG"
fi

(cd dist && shasum -a 256 ./*.dmg ./*.zip | sed 's# \./# #' > SHA256SUMS.txt)
echo "==> Packaged:"
ls -lh dist
