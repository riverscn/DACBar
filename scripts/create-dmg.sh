#!/bin/bash
set -euo pipefail

APP="${1:-dist/DACBar.app}"
OUTPUT="${2:-dist/DACBar.dmg}"
VOLUME_NAME="${3:-DACBar}"

fail() {
    echo "error: $*" >&2
    exit 1
}

[ -d "$APP/Contents" ] || fail "missing app bundle: $APP"
[ "$(basename "$APP")" = "DACBar.app" ] \
    || fail "the disk image must contain DACBar.app"
[ -n "$VOLUME_NAME" ] || fail "volume name must not be empty"

TEMP_ROOT="${TMPDIR:-/tmp}"
STAGING=$(mktemp -d "$TEMP_ROOT/dacbar-dmg.XXXXXX")
cleanup() {
    rm -rf "$STAGING"
}
trap cleanup EXIT

# Keep the disk image deliberately simple. The application is the only payload;
# the absolute symlink gives Finder users the conventional drag-install target.
ditto "$APP" "$STAGING/DACBar.app"
ln -s /Applications "$STAGING/Applications"

mkdir -p "$(dirname "$OUTPUT")"
rm -f "$OUTPUT"
hdiutil create -quiet \
    -fs APFS \
    -format ULFO \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING" \
    "$OUTPUT"

echo "created $OUTPUT (APFS, LZFSE, read-only)"
