#!/bin/bash
set -euo pipefail

DMG="${1:-dist/DACBar.dmg}"
REQUIRE_DISTRIBUTION="${DACBAR_REQUIRE_DISTRIBUTION:-0}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

fail() {
    echo "error: $*" >&2
    exit 1
}

[ -f "$DMG" ] || fail "missing disk image: $DMG"

TEMP_ROOT="${TMPDIR:-/tmp}"
WORK_DIR=$(mktemp -d "$TEMP_ROOT/dacbar-dmg-validation.XXXXXX")
MOUNT_POINT="$WORK_DIR/mount"
INFO_PLIST="$WORK_DIR/imageinfo.plist"
mkdir "$MOUNT_POINT"
ATTACHED=0
cleanup() {
    if [ "$ATTACHED" = "1" ]; then
        hdiutil detach -quiet "$MOUNT_POINT" >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

hdiutil imageinfo -plist "$DMG" > "$INFO_PLIST"
FORMAT=$(plutil -extract Format raw "$INFO_PLIST")
[ "$FORMAT" = "ULFO" ] || fail "expected LZFSE-compressed ULFO image, found $FORMAT"
grep -q '<string>Apple_APFS</string>' "$INFO_PLIST" \
    || fail "disk image is not APFS"

codesign --verify --strict --verbose=2 "$DMG"

hdiutil attach -quiet -readonly -nobrowse -mountpoint "$MOUNT_POINT" "$DMG"
ATTACHED=1
[ -d "$MOUNT_POINT/DACBar.app/Contents" ] || fail "disk image is missing DACBar.app"
[ -L "$MOUNT_POINT/Applications" ] || fail "disk image is missing the Applications symlink"
[ "$(readlink "$MOUNT_POINT/Applications")" = "/Applications" ] \
    || fail "Applications symlink does not target /Applications"
TOP_LEVEL_ENTRIES=$(find "$MOUNT_POINT" -mindepth 1 -maxdepth 1 -exec basename {} \; \
    | LC_ALL=C sort)
EXPECTED_ENTRIES=$(printf '%s\n' Applications DACBar.app)
[ "$TOP_LEVEL_ENTRIES" = "$EXPECTED_ENTRIES" ] \
    || fail "disk image contains unexpected top-level entries: $TOP_LEVEL_ENTRIES"

"$SCRIPT_DIR/validate-app.sh" "$MOUNT_POINT/DACBar.app"

if [ "$REQUIRE_DISTRIBUTION" = "1" ]; then
    SIGNING=$(codesign -dv --verbose=4 "$DMG" 2>&1)
    grep -q '^Authority=Developer ID Application:' <<<"$SIGNING" \
        || fail "disk image is not signed by Developer ID Application"
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

echo "validated $DMG (APFS, LZFSE, signed, DACBar.app + Applications symlink)"
