#!/usr/bin/env bash
# ==============================================================================
# Thin entrypoint for Declarative Sharded Test Runner (run_sharded_pytest.py).
# Keeps snapshot_root.sh -> test_databases.sh -> template_lock.sh sourcing
# intact (preserving B4a per-key publish.lock / flock -s and 1e85fa03a
# ENACT_TEMPLATE_SNAPSHOT_DIR without touching test_databases.sh).
# ==============================================================================
set -euo pipefail

_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${1:-}" = "--provision-db" ]; then
    _out_json="${2:?missing env output path}"
    _shard="${3:-1}"
    if [ -f "$_SCRIPTS_DIR/snapshot_root.sh" ]; then
        # shellcheck source=snapshot_root.sh
        source "$_SCRIPTS_DIR/snapshot_root.sh"
    fi
    # shellcheck source=test_databases.sh
    source "$_SCRIPTS_DIR/test_databases.sh"
    if [ -f "$_SCRIPTS_DIR/template_lock.sh" ]; then
        # shellcheck source=template_lock.sh
        source "$_SCRIPTS_DIR/template_lock.sh"
    fi
    WORKER_ID="$(test_worker_name "${ENACT_COMPONENT:-}" "${ENACT_JOB:-}" "$_shard")"
    prepare_worker_databases "$WORKER_ID"
    export ENACT_WORKER_ID="$WORKER_ID"
    python3 -c 'import json, os, pathlib, sys; pathlib.Path(sys.argv[1]).write_text(json.dumps(dict(os.environ)), encoding="utf-8")' "$_out_json"
    exit 0
fi

exec python3 "$_SCRIPTS_DIR/run_sharded_pytest.py" "$@"
