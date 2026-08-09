#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="DACBar"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/DACBar.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/DACBar"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

cd "$ROOT_DIR"
./build.sh debug
APP_ID=$(plutil -extract CFBundleIdentifier raw "$APP_BUNDLE/Contents/Info.plist")

open_app() {
    /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
    run)
        open_app
        ;;
    --debug|debug)
        lldb -- "$APP_BINARY"
        ;;
    --logs|logs)
        open_app
        /usr/bin/log stream --info --style compact \
            --predicate "process == \"$APP_NAME\""
        ;;
    --telemetry|telemetry)
        open_app
        /usr/bin/log stream --info --style compact \
            --predicate "subsystem == \"$APP_ID\" OR subsystem == \"ShanlingUA1II\""
        ;;
    --verify|verify)
        open_app
        sleep 1
        pgrep -x "$APP_NAME" >/dev/null
        ;;
    *)
        echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
        exit 2
        ;;
esac
