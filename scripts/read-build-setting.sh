#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
SETTING="${1:-}"
CONFIGURATION="${2:-Release}"

[[ "$SETTING" =~ ^[A-Z][A-Z0-9_]*$ ]] || {
    echo "error: build setting name must contain uppercase letters, numbers, or underscores" >&2
    exit 1
}
case "$CONFIGURATION" in
    Debug|Release|Distribution) ;;
    *) echo "error: configuration must be Debug, Release, or Distribution: $CONFIGURATION" >&2; exit 1 ;;
esac

BUILD_SETTINGS=$(xcodebuild \
    -project "$ROOT_DIR/DACBar.xcodeproj" \
    -target DACBar \
    -configuration "$CONFIGURATION" \
    -disableAutomaticPackageResolution \
    -showBuildSettings)

VALUE=$(printf '%s\n' "$BUILD_SETTINGS" \
    | awk -F ' = ' -v setting="$SETTING" \
        '$1 ~ "^[[:space:]]*" setting "$" { print $2; exit }')

[ -n "$VALUE" ] || {
    echo "error: Xcode did not resolve build setting: $SETTING" >&2
    exit 1
}

printf '%s\n' "$VALUE"
