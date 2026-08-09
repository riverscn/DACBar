#!/bin/bash
set -euo pipefail

APP="${1:-dist/DACBar.app}"
REQUIRE_DISTRIBUTION="${DACBAR_REQUIRE_DISTRIBUTION:-0}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
EXPECTED_APP_ID="${DACBAR_EXPECTED_APP_ID:-}"

if [ -z "$EXPECTED_APP_ID" ]; then
    EXPECTED_APP_ID=$("$SCRIPT_DIR/read-build-setting.sh" \
        PRODUCT_BUNDLE_IDENTIFIER Distribution)
fi

fail() {
    echo "error: $*" >&2
    exit 1
}

[ -d "$APP/Contents" ] || fail "missing app bundle: $APP"
[ -x "$APP/Contents/MacOS/DACBar" ] || fail "missing executable"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

APP_ID=$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")
VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
BUILD=$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")
MIN_OS=$(plutil -extract LSMinimumSystemVersion raw "$APP/Contents/Info.plist")
AUTOMATIC_UPDATE=$(plutil -extract SUAutomaticallyUpdate raw "$APP/Contents/Info.plist")
CHECK_INTERVAL=$(plutil -extract SUScheduledCheckInterval raw "$APP/Contents/Info.plist")
REQUIRE_SIGNED_FEED=$(plutil -extract SURequireSignedFeed raw "$APP/Contents/Info.plist")
VERIFY_BEFORE_EXTRACTION=$(plutil -extract SUVerifyUpdateBeforeExtraction raw "$APP/Contents/Info.plist")

[[ "$APP_ID" =~ ^[A-Za-z0-9][A-Za-z0-9.-]+$ ]] || fail "invalid bundle identifier: $APP_ID"
[ "$APP_ID" = "$EXPECTED_APP_ID" ] \
    || fail "unexpected bundle identifier: $APP_ID (expected $EXPECTED_APP_ID)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid version: $VERSION"
[[ "$BUILD" =~ ^[1-9][0-9]*$ ]] || fail "invalid build number: $BUILD"
[ "$MIN_OS" = "14.0" ] || fail "unexpected deployment target: $MIN_OS"
[ "$AUTOMATIC_UPDATE" = "true" ] || fail "Sparkle automatic installation is disabled"
[ "$CHECK_INTERVAL" = "86400" ] || fail "unexpected Sparkle check interval: $CHECK_INTERVAL"
[ "$REQUIRE_SIGNED_FEED" = "true" ] || fail "Sparkle signed-feed verification is disabled"
[ "$VERIFY_BEFORE_EXTRACTION" = "true" ] || fail "Sparkle pre-extraction verification is disabled"
if plutil -extract SUEnableAutomaticChecks raw \
        "$APP/Contents/Info.plist" >/dev/null 2>&1; then
    fail "automatic checks are forced instead of using Sparkle's permission prompt"
fi
if plutil -extract SUAllowsAutomaticUpdates raw \
        "$APP/Contents/Info.plist" >/dev/null 2>&1; then
    fail "automatic installation is forced instead of using the user's choice"
fi
if plutil -extract SUEnableInstallerLauncherService raw \
        "$APP/Contents/Info.plist" >/dev/null 2>&1; then
    fail "non-sandboxed build enables Sparkle Installer XPC service"
fi
if plutil -extract SUEnableDownloaderService raw \
        "$APP/Contents/Info.plist" >/dev/null 2>&1; then
    fail "non-sandboxed build enables Sparkle Downloader XPC service"
fi

verify_universal() {
    local binary="$1"
    local architectures
    architectures=$(lipo -archs "$binary")
    case "$architectures" in
        "arm64 x86_64"|"x86_64 arm64") ;;
        *) fail "expected arm64 and x86_64 only, found $architectures in $binary" ;;
    esac
}

verify_universal "$APP/Contents/MacOS/DACBar"

[ -f "$APP/Contents/Resources/Assets.car" ] || fail "missing compiled icon catalog"
[ -f "$APP/Contents/Resources/AppIcon.icns" ] || fail "missing fallback app icon"
[ -d "$APP/Contents/Frameworks/Sparkle.framework" ] || fail "missing Sparkle framework"
[ -f "$APP/Contents/Resources/Sparkle-LICENSE.txt" ] \
    || fail "missing Sparkle license notice"
[ -f "$APP/Contents/Resources/en.lproj/Localizable.strings" ] \
    || fail "missing English app strings"
[ -f "$APP/Contents/Resources/zh-Hans.lproj/Localizable.strings" ] \
    || fail "missing Simplified Chinese app strings"
for RESOURCE_BUNDLE in \
    DACDevices_DACDeviceKit.bundle \
    DACDevices_ShanlingUA1II.bundle; do
    [ -d "$APP/Contents/Resources/$RESOURCE_BUNDLE" ] \
        || fail "missing resource bundle: $RESOURCE_BUNDLE"
    [ -f "$APP/Contents/Resources/$RESOURCE_BUNDLE/Contents/Resources/en.lproj/Localizable.strings" ] \
        || fail "missing English strings in $RESOURCE_BUNDLE"
    [ -f "$APP/Contents/Resources/$RESOURCE_BUNDLE/Contents/Resources/zh-Hans.lproj/Localizable.strings" ] \
        || fail "missing Simplified Chinese strings in $RESOURCE_BUNDLE"
done

for RESOURCE_BUNDLE_PATH in "$APP"/Contents/Resources/*.bundle; do
    RESOURCE_BUNDLE=$(basename "$RESOURCE_BUNDLE_PATH")
    case "$RESOURCE_BUNDLE" in
        DACDevices_DACDeviceKit.bundle|DACDevices_ShanlingUA1II.bundle) ;;
        *) fail "unexpected resource bundle retained: $RESOURCE_BUNDLE" ;;
    esac
done

codesign --verify --deep --strict --verbose=2 "$APP"

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
[ ! -e "$SPARKLE/XPCServices" ] && [ ! -L "$SPARKLE/XPCServices" ] \
    || fail "unused Sparkle XPC services are present"
[ ! -e "$APP/Contents/Frameworks/Sparkle.framework/XPCServices" ] \
    && [ ! -L "$APP/Contents/Frameworks/Sparkle.framework/XPCServices" ] \
    || fail "unused Sparkle XPCServices framework link is present"
for BINARY in \
    "$SPARKLE/Sparkle" \
    "$SPARKLE/Autoupdate" \
    "$SPARKLE/Updater.app/Contents/MacOS/Updater"; do
    verify_universal "$BINARY"
done

otool -L "$APP/Contents/MacOS/DACBar" \
    | grep -q '@rpath/Sparkle.framework/Versions/B/Sparkle' \
    || fail "main executable is not linked to Sparkle"

if [ "$REQUIRE_DISTRIBUTION" = "1" ]; then
    [[ "$APP_ID" != local.* ]] || fail "distribution build uses a local bundle identifier"
    FEED_URL=$(plutil -extract SUFeedURL raw "$APP/Contents/Info.plist")
    PUBLIC_KEY=$(plutil -extract SUPublicEDKey raw "$APP/Contents/Info.plist")
    [[ "$FEED_URL" == https://* ]] || fail "missing HTTPS Sparkle feed URL"
    [[ "$PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] || fail "invalid Sparkle public key"
    SIGNING=$(codesign -dv --verbose=4 "$APP" 2>&1)
    grep -q '^Authority=Developer ID Application:' <<<"$SIGNING" \
        || fail "not signed by Developer ID Application"
    grep -q '^flags=.*runtime' <<<"$SIGNING" \
        || fail "hardened runtime is missing"
    ENTITLEMENTS=$(codesign -d --entitlements :- "$APP" 2>/dev/null || true)
    ! grep -q 'com.apple.security.app-sandbox' <<<"$ENTITLEMENTS" \
        || fail "distribution build unexpectedly enables App Sandbox"
    ! grep -q 'com.apple.security.cs.disable-library-validation' <<<"$ENTITLEMENTS" \
        || fail "distribution build contains the local debug entitlement"
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose=2 "$APP"
fi

echo "validated $APP ($APP_ID $VERSION+$BUILD, arm64+x86_64, macOS $MIN_OS+)"
