#!/bin/sh
# Builds Reclaim.app and the `reclaim` CLI from the SwiftPM targets (no Xcode project required).
#
#   ./scripts/build-app.sh             -> build/Reclaim.app and build/reclaim
#   ./scripts/build-app.sh --install   ...and copy the app to /Applications
#
# Environment:
#   VERSION         Marketing version (default: ReclaimInfo.version in Sources/ReclaimCore/Version.swift)
#   BUILD_NUMBER    CFBundleVersion (default: number of commits, or 1)
#   ARCHS           Space-separated architectures, e.g. "arm64 x86_64" for a universal build (needs Xcode)
#   SIGN_IDENTITY   Code signing identity (default: "-" for ad-hoc). A Developer ID enables the hardened runtime.
#   BUNDLE_ID       Bundle identifier (default: io.github.unfield.reclaim)
set -eu

cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/ReclaimCore/Version.swift)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
BUNDLE_ID="${BUNDLE_ID:-io.github.unfield.reclaim}"
ARCHS="${ARCHS:-}"

APP="build/Reclaim.app"
ICON="Resources/AppIcon.icns"

ARCH_FLAGS=""
for arch in $ARCHS; do ARCH_FLAGS="$ARCH_FLAGS --arch $arch"; done

if [ ! -f "$ICON" ]; then
    swift scripts/make-icon.swift "$ICON"
fi

# --disable-keychain: SwiftPM otherwise queries the keychain for credentials and can block on a prompt.
SWIFT_FLAGS="-c release --disable-keychain $ARCH_FLAGS"

echo "Building Reclaim $VERSION ($BUILD_NUMBER)${ARCHS:+ for $ARCHS}"
# shellcheck disable=SC2086
swift build $SWIFT_FLAGS --product ReclaimApp
# shellcheck disable=SC2086
swift build $SWIFT_FLAGS --product reclaim
# shellcheck disable=SC2086
BIN_DIR="$(swift build $SWIFT_FLAGS --show-bin-path)"

rm -rf "$APP" build/reclaim
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks" "$APP/Contents/Helpers"
cp "$BIN_DIR/ReclaimApp" "$APP/Contents/MacOS/Reclaim"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
# The CLI ships inside the app too (Homebrew links it as `reclaim`).
cp "$BIN_DIR/reclaim" "$APP/Contents/Helpers/reclaim"
cp "$BIN_DIR/reclaim" build/reclaim
if [ -d Localization ]; then
    cp -R Localization/*.lproj "$APP/Contents/Resources/"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Reclaim</string>
    <key>CFBundleDisplayName</key><string>Reclaim</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>Reclaim</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Open source under the MIT License.</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>de</string></array>
    <key>SUFeedURL</key><string>https://github.com/Unfield/Reclaim/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key><string>eeKDcidYBaZXwlIVv4C8UTGDR3E53oYrXqneH6xXiDg=</string>
    <key>SUEnableInstallerLauncherService</key><false/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <!-- Lets you drop an app on Reclaim's Dock icon to uninstall it. Rank None: never the default opener. -->
            <key>CFBundleTypeName</key><string>Application</string>
            <key>CFBundleTypeRole</key><string>None</string>
            <key>LSHandlerRank</key><string>None</string>
            <key>LSItemContentTypes</key><array><string>com.apple.application-bundle</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Sign inside-out: Sparkle's helpers, the framework, the CLI, then the app.
if [ "$SIGN_IDENTITY" = "-" ]; then
    # Ad-hoc signature: enough to run locally; downloads will need to be opened via right-click → Open.
    SIGN="codesign --force --sign -"
else
    SIGN="codesign --force --options runtime --timestamp --sign $SIGN_IDENTITY"
fi
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for item in "$SPARKLE/XPCServices/Installer.xpc" "$SPARKLE/Autoupdate" "$SPARKLE/Updater.app"; do
    [ -e "$item" ] && $SIGN "$item"
done
if [ -e "$SPARKLE/XPCServices/Downloader.xpc" ]; then
    $SIGN --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
fi
$SIGN "$APP/Contents/Frameworks/Sparkle.framework"
$SIGN "$APP/Contents/Helpers/reclaim"
$SIGN build/reclaim
$SIGN "$APP"
codesign --verify --deep --strict "$APP"

echo "Built $APP and build/reclaim"

if [ "${1:-}" = "--install" ]; then
    rm -rf "/Applications/Reclaim.app"
    cp -R "$APP" /Applications/
    echo "Installed /Applications/Reclaim.app"
fi
