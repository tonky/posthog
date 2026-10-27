#!/usr/bin/env bash
# `vitest <args…>` from the package's directory, as `pnpm exec vitest` runs it. Under
# enact's Node recorder (`enact trace run --node-functions` sets ENACT_NODE_COVERAGE_DIR)
# it adds node_marker.mjs, a reporter giving each Node worker a setup file that ends
# its test file's record after the file's last hook, before vitest stops the worker (a
# SIGTERM, then a SIGKILL 500 ms later, or a thread's terminate()).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
reporters=()
if [ -n "${ENACT_NODE_COVERAGE_DIR:-}" ]; then
    reporters=(--reporter=default "--reporter=${here}/node_marker.mjs")
fi
exec pnpm exec vitest "$@" ${reporters[@]+"${reporters[@]}"}
