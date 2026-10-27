#!/usr/bin/env bash
# Runs a generator, then fails when it changed a tracked file: upstream's `git diff
# --exit-code` after a regeneration, on a checkout the overlay's patches already modify (a
# bare `git diff --exit-code` fails on them). The tracked files that differ from HEAD, by
# content hash, before and after; the files whose state the command changed are the drift.
#
#   showcase/scripts/no_drift.sh <command...>     (from the checkout's root)
set -euo pipefail
[ "$#" -gt 0 ] || { echo "usage: no_drift.sh <command...>" >&2; exit 64; }

state() {
    git diff --name-only -z | xargs -0 sha256sum -- /dev/null
}

before="$(state)"
"$@"
after="$(state)"
# diff exits 1 on a difference: the lines are the answer, not its status.
drifted="$({ diff <(echo "$before") <(echo "$after") || true; } | sed -n 's/^[<>] [0-9a-f]* *//p' | sort -u)"
if [ -n "$drifted" ]; then
    echo "✗ no_drift.sh: \`$*\` changed tracked files:" >&2
    echo "$drifted" >&2
    echo "$drifted" | tr '\n' '\0' | xargs -0 git diff -- | head -200 >&2
    exit 1
fi
echo "✓ no_drift.sh: \`$*\` changed no tracked file"
