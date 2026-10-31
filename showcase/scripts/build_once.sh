#!/usr/bin/env bash
# Runs a build once per source state of what it reads:
#
#   showcase/scripts/build_once.sh <name> <stamp file> <input path...> -- <command...>
#
# Delegates to `enact helper build-once`.
set -euo pipefail

name="${1:?usage: build_once.sh <name> <stamp file> <input path...> -- <command...>}"
stamp="${2:?usage: build_once.sh <name> <stamp file> <input path...> -- <command...>}"
shift 2
inputs=()
while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do inputs+=("$1"); shift; done
[ "$#" -gt 1 ] && [ "${#inputs[@]}" -gt 0 ] || { echo "usage: build_once.sh <name> <stamp file> <input path...> -- <command...>" >&2; exit 64; }
shift

export ENACT_LOCKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.enact/state/locks"
enact="${ENACT_EXE:-${ENACT_BIN:-$(command -v enact)}}"
exec "${enact}" helper build-once --name "${name}" --stamp "${stamp}" --inputs "${inputs[@]}" -- "$@"
