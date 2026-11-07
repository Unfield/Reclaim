#!/bin/sh
# Builds and packages a release into dist/:
#   Reclaim-<version>.dmg              drag-to-Applications disk image
#   Reclaim-<version>.zip              the app, zipped
#   reclaim-cli-<version>-macos.tar.gz the command-line tool
#   SHA256SUMS.txt
#
# Takes the same environment variables as build-app.sh. If NOTARY_APPLE_ID, NOTARY_TEAM_ID and
# NOTARY_PASSWORD are set (and SIGN_IDENTITY is a Developer ID), the app and DMG are notarized and stapled.
set -eu

cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/ReclaimCore/Version.swift)}"
export VERSION
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

./scripts/build-app.sh

NOTARIZE=false
if [ "$SIGN_IDENTITY" != "-" ] && [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_TEAM_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ]; then
    NOTARIZE=true
fi

notarize() {
    echo "Notarizing $1…"
    xcrun notarytool submit "$1" \
        --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD" --wait
}

rm -rf dist
mkdir -p dist

ZIP="dist/Reclaim-$VERSION.zip"
DMG="dist/Reclaim-$VERSION.dmg"
CLI="dist/reclaim-cli-$VERSION-macos.tar.gz"

if [ "$NOTARIZE" = true ]; then
    ditto -c -k --keepParent build/Reclaim.app "$ZIP"
    notarize "$ZIP"
    xcrun stapler staple build/Reclaim.app
    rm "$ZIP"
fi
ditto -c -k --keepParent build/Reclaim.app "$ZIP"

STAGING="$(mktemp -d)"
cp -R build/Reclaim.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Reclaim $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"
if [ "$SIGN_IDENTITY" != "-" ]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi
if [ "$NOTARIZE" = true ]; then
    notarize "$DMG"
    xcrun stapler staple "$DMG"
fi

tar -czf "$CLI" -C build reclaim

(cd dist && shasum -a 256 ./*.dmg ./*.zip ./*.tar.gz | sed 's| \./| |' > SHA256SUMS.txt)

echo
echo "Release artifacts:"
ls -lh dist
[ "$NOTARIZE" = true ] && echo "Notarized and stapled." || echo "Not notarized (ad-hoc signed)."
