#!/usr/bin/env bash
# Runs a command while no other command holding the same lock runs in this checkout:
#
#   showcase/scripts/exclusive.sh <lock name> <command...>
#
# Delegates to `enact helper lock`.
set -euo pipefail

name="${1:?usage: exclusive.sh <lock name> <command...>}"
shift
[ "$#" -gt 0 ] || { echo "usage: exclusive.sh <lock name> <command...>" >&2; exit 64; }

export ENACT_LOCKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.enact/state/locks"
enact="${ENACT_EXE:-${ENACT_BIN:-$(command -v enact)}}"
exec "${enact}" helper lock "${name}" -- "$@"
