#!/bin/bash
# Writes dist/appcast.xml, the feed Sparkle reads to find updates, for the
# ZIP that package.sh just made. Published with each GitHub release, it's
# served at https://github.com/TheBEACONFoundation/Tidewall/releases/latest/download/appcast.xml
#
#   Scripts/make-appcast.sh dist/Tidewall-1.2.0.zip
#
# The ZIP is signed with Tidewall's private EdDSA key: from SPARKLE_PRIVATE_KEY
# (CI), or else from the login keychain (account "tidewall", made by
# `generate_keys --account tidewall`).
set -euo pipefail
cd "$(dirname "$0")/.."

ZIP="$1"
APP="build/Tidewall.app"
REPO="TheBEACONFoundation/Tidewall"
BIN=".build/artifacts/sparkle/Sparkle/bin"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
MINIMUM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"

if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    SIGNATURE="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$BIN/sign_update" --ed-key-file - "$ZIP")"
else
    SIGNATURE="$("$BIN/sign_update" --account tidewall "$ZIP")"
fi

cat > dist/appcast.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Tidewall</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>Tidewall $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINIMUM</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases/tag/v$VERSION</sparkle:fullReleaseNotesLink>
      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/$(basename "$ZIP")"
                 type="application/octet-stream" $SIGNATURE />
    </item>
  </channel>
</rss>
EOF
echo "==> Wrote dist/appcast.xml for $VERSION ($BUILD)"
