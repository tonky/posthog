#!/usr/bin/env bash
# Whole-repository pytest guards, as upstream's "Repo checks" job runs them.
# Runs on its own database clones so it never touches the templates or the
# test shards that run at the same time.
set -euo pipefail
export PATH="$PWD/bin:$PATH"
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
NUM_WORKERS="${PYTEST_NUM_WORKERS:-$(nproc 2>/dev/null || echo 2)}"
# The import budget times django.setup() in child processes: beside the other workers it
# measured their load. It runs after them, on its own, as upstream runs the directory (one
# process, no xdist).
timed=posthog/test/repo_invariants/test_startup_import_budget.py::test_no_new_heavy_imports_at_setup
pytest() {
    # The backend runtime is installed before the run (ci.cue's toolchain.python.install).
    env -u E2E_TESTING python3 showcase/scripts/backend_runtime.py exec uv run --no-sync python -m pytest \
        -p no:cacheprovider -o pythonhashseed=0 ${reuse[@]+"${reuse[@]}"} "$@"
}
pytest -n "$NUM_WORKERS" posthog/test/repo_invariants --deselect "$timed"
pytest "$timed"
