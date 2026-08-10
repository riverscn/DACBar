#!/bin/bash
set -euo pipefail

command -v actionlint >/dev/null || {
    echo "error: actionlint is required" >&2
    exit 1
}
command -v shellcheck >/dev/null || {
    echo "error: ShellCheck is required" >&2
    exit 1
}

actionlint
shellcheck build.sh scripts/*.sh
