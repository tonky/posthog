#!/usr/bin/env bash
# Pick N unused loopback ports and print them on stdout (or release with --release <p0> <n>).
# Delegates to `enact helper free-ports` (`F-shell-loop-free-ports-timeout`).
set -euo pipefail

enact="${ENACT_EXE:-${ENACT_BIN:-$(command -v enact)}}"
if [ "${1:-}" = "--release" ]; then
    [ -n "${2:-}" ] && [ -n "${3:-}" ] || exit 0
    exec "${enact}" helper free-ports --owner "${PORTS_OWNER:-${PPID}}" --release "$2" "$3"
fi
exec "${enact}" helper free-ports --count "${1:-1}" --owner "${PORTS_OWNER:-${PPID}}" ${FREE_PORTS_RANGE:+--range "${FREE_PORTS_RANGE}"}
