#!/usr/bin/env bash
# Runs a command while no other command holding the same lock runs in this checkout:
#
#   showcase/scripts/exclusive.sh <lock name> <command...>
#
# For what the test runners themselves install into the checkout (node_modules, the GeoIP
# database). The declared toolchain install (ci.cue's toolchain.python.install, the uv venv)
# runs once before any shard, in CI's install step and a local `enact run`'s prepare phase;
# what a task's own script installs has no such step, and a local `enact run` starts a job's
# shards, and other jobs, side by side in one checkout. Unlocked, they collided
# (GeoLite2 `File exists`). The command must look before it installs
# (bin/download-mmdb, a frozen-lockfile pnpm install), so the callers that waited find the
# work done. The command runs in the caller's directory; its exit status is the caller's,
# with no fallback.
set -euo pipefail

name="${1:?usage: exclusive.sh <lock name> <command...>}"
shift
[ "$#" -gt 0 ] || { echo "usage: exclusive.sh <lock name> <command...>" >&2; exit 64; }

# Next to test_databases.sh's lock: the checkout's own, whichever directory the caller runs in.
locks="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.enact/state/locks"
mkdir -p "$locks"
exec 9>"$locks/$name.lock"
flock 9
# This shell holds the lock until the command ends; the command doesn't get the descriptor,
# so a daemon it leaves running (turbo's) can't hold the lock after it.
"$@" 9>&-
