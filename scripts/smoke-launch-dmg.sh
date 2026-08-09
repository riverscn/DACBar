#!/bin/bash
set -euo pipefail

DMG="${1:?usage: smoke-launch-dmg.sh /path/to/DACBar.dmg}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

[ -f "$DMG" ] || {
    echo "error: missing disk image: $DMG" >&2
    exit 1
}

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/dacbar-dmg-launch.XXXXXX")
MOUNT_POINT="$WORK_DIR/mount"
mkdir "$MOUNT_POINT"
ATTACHED=0

cleanup() {
    if [ "$ATTACHED" = "1" ]; then
        hdiutil detach -quiet "$MOUNT_POINT" >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

hdiutil attach -quiet -readonly -nobrowse -mountpoint "$MOUNT_POINT" "$DMG"
ATTACHED=1
"$SCRIPT_DIR/smoke-launch-app.sh" "$MOUNT_POINT/DACBar.app"
