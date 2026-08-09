#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CONFIGURATION="${1:-Distribution}"

case "$CONFIGURATION" in
    Debug|Release|Distribution) ;;
    *) echo "error: configuration must be Debug, Release, or Distribution: $CONFIGURATION" >&2; exit 1 ;;
esac

VERSION=$("$SCRIPT_DIR/read-build-setting.sh" MARKETING_VERSION "$CONFIGURATION")

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "error: Xcode resolved an invalid MARKETING_VERSION: ${VERSION:-<missing>}" >&2
    exit 1
}

printf '%s\n' "$VERSION"
