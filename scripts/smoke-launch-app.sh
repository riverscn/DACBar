#!/bin/bash
set -euo pipefail

APP="${1:?usage: smoke-launch-app.sh /path/to/App.app}"
EXECUTABLE_NAME=$(plutil -extract CFBundleExecutable raw \
    "$APP/Contents/Info.plist")
BINARY="$APP/Contents/MacOS/$EXECUTABLE_NAME"
LOG_FILE=$(mktemp -t dacbar-launch-smoke.XXXXXX)
PID=""

cleanup() {
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        kill "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
    fi
    rm -f "$LOG_FILE"
}
trap cleanup EXIT

[ -x "$BINARY" ] || {
    echo "error: missing app executable: $BINARY" >&2
    exit 1
}

"$BINARY" >"$LOG_FILE" 2>&1 &
PID=$!

# dyld/library-validation failures exit immediately. Keeping the menu-bar app
# alive for two seconds proves that launch reached its event loop.
for _ in {1..20}; do
    if ! PROCESS_STATE=$(ps -p "$PID" -o state= 2>/dev/null); then
        PROCESS_STATE=""
    fi
    PROCESS_STATE=${PROCESS_STATE//[[:space:]]/}
    case "$PROCESS_STATE" in
    ""|Z*)
        set +e
        wait "$PID"
        STATUS=$?
        set -e
        PID=""
        cat "$LOG_FILE" >&2
        echo "error: app exited during launch smoke test (status $STATUS)" >&2
        exit 1
        ;;
    esac
    sleep 0.1
done

kill "$PID"
wait "$PID" 2>/dev/null || true
PID=""
echo "launch smoke test passed: $APP"
