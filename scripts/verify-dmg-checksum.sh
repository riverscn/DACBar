#!/bin/bash
set -euo pipefail

DMG="${1:?usage: verify-dmg-checksum.sh /path/to/DACBar.dmg /path/to/DACBar.dmg.sha256}"
CHECKSUM="${2:?usage: verify-dmg-checksum.sh /path/to/DACBar.dmg /path/to/DACBar.dmg.sha256}"

fail() {
    echo "error: $*" >&2
    exit 1
}

[ -f "$DMG" ] || fail "missing disk image: $DMG"
[ -f "$CHECKSUM" ] || fail "missing checksum: $CHECKSUM"

DMG_DIRECTORY=$(cd "$(dirname "$DMG")" && pwd -P)
CHECKSUM_DIRECTORY=$(cd "$(dirname "$CHECKSUM")" && pwd -P)
[ "$DMG_DIRECTORY" = "$CHECKSUM_DIRECTORY" ] \
    || fail "disk image and checksum must be in the same directory"

DMG_BASENAME=$(basename "$DMG")
CHECKSUM_BASENAME=$(basename "$CHECKSUM")
LINE_COUNT=$(wc -l < "$CHECKSUM")
[ "$LINE_COUNT" -eq 1 ] || fail "checksum must contain exactly one record"

RECORDED_BASENAME=$(awk '
    NF == 2 && $1 ~ /^[0-9a-fA-F]{64}$/ { print $2 }
' "$CHECKSUM")
[ "$RECORDED_BASENAME" = "$DMG_BASENAME" ] \
    || fail "checksum records '$RECORDED_BASENAME', expected '$DMG_BASENAME'"

(
    cd "$DMG_DIRECTORY"
    shasum -a 256 --check "$CHECKSUM_BASENAME"
)
