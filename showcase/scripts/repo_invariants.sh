#!/usr/bin/env bash
# Whole-repository pytest guards, as upstream's "Repo checks" job runs them.
# Runs on its own database clones so it never touches the templates or the
# test shards that run at the same time.
set -euo pipefail
junit=()
if [[ -n "${ENACT_REPLAY_RESULTS:-}" ]]; then
    mkdir -p "$ENACT_REPLAY_RESULTS"
    junit=(--junit-xml "$ENACT_REPLAY_RESULTS/repo-invariants.xml")
fi
reuse=()
# Same probe as run_sharded_pytest.sh: the harness starts services around the
# run, so the runner's ENACT_SERVICES_ACTIVE flag says nothing about them.
export PGHOST="${PGHOST:-127.0.0.2}" PGUSER="${PGUSER:-posthog}" PGPASSWORD="${PGPASSWORD:-posthog}"
if [ -n "${PGPORT:-}" ] && pg_isready -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -q; then
    # shellcheck source=test_databases.sh
    source "$(dirname "${BASH_SOURCE[0]}")/test_databases.sh"
    # The digits pick the worker's Redis database, past the shards' 1..8.
    prepare_worker_databases "audit9"
    reuse=(--reuse-db)
fi
exec python3 showcase/scripts/backend_runtime.py exec uv run --no-sync python -m pytest \
    -p no:cacheprovider -o pythonhashseed=0 "${reuse[@]}" "${junit[@]}" posthog/test/repo_invariants
