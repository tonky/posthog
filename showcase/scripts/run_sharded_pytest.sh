#!/usr/bin/env bash
# ==============================================================================
# Declarative Sharded Test Runner with Automatic Database Isolation
# Provisions isolated PostgreSQL & ClickHouse database slices per shard:
#   • test_posthog_shard${SHARD}
#   • test_posthog_persons_shard${SHARD}
#   • test_dagster_shard${SHARD}
#   • posthog_test_shard${SHARD}
# ==============================================================================
set -euo pipefail
unset LD_PRELOAD

SHARD="${ENACT_SHARD_INDEX:-${SHARD:-1}}"
TOTAL="${ENACT_SHARD_TOTAL:-${TOTAL_SHARDS:-1}}"

PG_HOST="${PGHOST:-127.0.0.1}"
PG_PORT="${PGPORT:-15432}"
PG_USER="${PGUSER:-posthog}"

if [ "$#" -eq 0 ] && [ -z "${ENACT_TARGETS_FILE:-}" ]; then
    echo "Explicit test targets are required" >&2
    exit 2
fi

SERVICES_ACTIVE="${ENACT_SERVICES_ACTIVE:-1}"
if [ -z "${PGPORT:-}" ] || [ "${SERVICES_ACTIVE}" = "0" ]; then
    SERVICES_ACTIVE="0"
fi

if [ "$SERVICES_ACTIVE" = "1" ]; then
    export PGHOST="${PG_HOST}"
    export PGPORT="${PG_PORT}"
    export PGUSER="${PG_USER}"
    export PGPASSWORD="posthog"
    export POSTHOG_DB_USER="${PG_USER}"
    export POSTHOG_DB_PASSWORD="posthog"
    export POSTHOG_POSTGRES_PORT="${PG_PORT}"
    export POSTHOG_POSTGRES_HOST="${PG_HOST}"

    # Wait for Postgres socket readiness
    until pg_isready -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -q; do
        sleep 0.1
    done
fi

# Enact already assigns targets to each shard; do not split them again in pytest.
if [ "$TOTAL" -gt 1 ]; then
    WORKER_ID="shard${SHARD}"
    POSTHOG_DB="test_posthog_${WORKER_ID}"
    PERSONS_DB="${POSTHOG_DB}_persons"
    DAGSTER_DB="test_dagster_${WORKER_ID}"
    CH_DB="posthog_test_${WORKER_ID}"

    if [ "$SERVICES_ACTIVE" = "1" ]; then
        # 1. Clone test_posthog if needed
        if ! psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$POSTHOG_DB'" | rg -q 1; then
            psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres -c "CREATE DATABASE $POSTHOG_DB TEMPLATE test_posthog;" >/dev/null 2>&1 || true
        fi

        # 2. Clone test_posthog_persons if needed
        if ! psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$PERSONS_DB'" | rg -q 1; then
            psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres -c "CREATE DATABASE $PERSONS_DB TEMPLATE test_posthog_persons;" >/dev/null 2>&1 || true
        fi

        # 3. Fresh isolated test_dagster per shard with zero sequence drift
        if ! psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$DAGSTER_DB'" | rg -q 1; then
            psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres -c "CREATE DATABASE $DAGSTER_DB;" >/dev/null 2>&1 || true
        fi
        psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$DAGSTER_DB" -c "TRUNCATE runs, run_tags, event_logs, daemon_heartbeats, snapshots, backfill_tags, bulk_actions, job_ticks, jobs RESTART IDENTITY CASCADE;" >/dev/null 2>&1 || true

        # 4. ClickHouse isolated database
        clickhouse-client -q "CREATE DATABASE IF NOT EXISTS $CH_DB;" >/dev/null 2>&1 || true

        # Export isolation variables
        # TOX_PARALLEL_ENV ensures pytest-django scopes the database name to test_posthog_shard${SHARD}
        export TOX_PARALLEL_ENV="${WORKER_ID}"
        export PYTEST_XDIST_WORKER="${WORKER_ID}"
        export DAGSTER_TEST_POSTGRES_URL="postgresql://${PG_USER}:${PG_USER}@${PG_HOST}:${PG_PORT}/${DAGSTER_DB}"
        export PERSONS_DB_WRITER_URL="postgres://${PG_USER}:${PG_USER}@${PG_HOST}:${PG_PORT}/${PERSONS_DB}"
        export PERSONS_DATABASE_URL="postgres://${PG_USER}:${PG_USER}@${PG_HOST}:${PG_PORT}/${PERSONS_DB}"
        export CLICKHOUSE_DATABASE="${CH_DB}"
    fi

    # Memory & Python Runtime Optimizations
    unset LD_PRELOAD
    export PYTHONNODEBUGRANGES="${PYTHONNODEBUGRANGES:-1}"
    export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"
    export MALLOC_ARENA_MAX="${MALLOC_ARENA_MAX:-2}"
    export MALLOC_TRIM_THRESHOLD_="${MALLOC_TRIM_THRESHOLD_:-131072}"
    export MALLOC_MMAP_THRESHOLD_="${MALLOC_MMAP_THRESHOLD_:-131072}"
    export PYTHON_GC_THRESHOLD_0="${PYTHON_GC_THRESHOLD_0:-10000}"
    export PYTHON_GC_THRESHOLD_1="${PYTHON_GC_THRESHOLD_1:-10}"
    export PYTHON_GC_THRESHOLD_2="${PYTHON_GC_THRESHOLD_2:-10}"
    export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
    export AWS_REGION="${AWS_REGION:-us-east-1}"

    # Resolve test targets (supports @argfile, raw file path, positional args, or $ENACT_TARGETS_FILE)
    TARGETS=()
    if [ "$#" -eq 1 ] && [[ "$1" == @* || ( -f "$1" && "$1" == *.txt ) ]]; then
        RAW_ARG="$1"
        FILE_PATH="${RAW_ARG#@}"
        if [ -f "$FILE_PATH" ]; then
            if ! rg -v -q '^[[:space:]]*$' "$FILE_PATH" 2>/dev/null; then
                echo "ℹ️  No test targets found in $FILE_PATH. Skipping pytest."
                exit 0
            fi
            mapfile -t TARGETS < <(rg -v '^[[:space:]]*$' "$FILE_PATH")
        else
            TARGETS=("$RAW_ARG")
        fi
    elif [ "$#" -gt 0 ]; then
        TARGETS=("$@")
    elif [ -n "${ENACT_TARGETS_FILE:-}" ] && [ -f "${ENACT_TARGETS_FILE}" ]; then
        if ! rg -v -q '^[[:space:]]*$' "${ENACT_TARGETS_FILE}" 2>/dev/null; then
            echo "ℹ️  No test targets found in ${ENACT_TARGETS_FILE}. Skipping pytest."
            exit 0
        fi
        mapfile -t TARGETS < <(rg -v '^[[:space:]]*$' "${ENACT_TARGETS_FILE}")
    fi

    # Execute pytest partitioned for this shard with --reuse-db
    set +e
    REUSE_DB_ARG=""
    if [ "$SERVICES_ACTIVE" = "1" ]; then
        REUSE_DB_ARG="--reuse-db"
    fi
    python3 showcase/scripts/backend_runtime.py exec uv run --no-sync python -m pytest -p showcase.scripts.pytest_timings -o pythonhashseed=0 --import-mode=importlib -v $REUSE_DB_ARG "${TARGETS[@]}"
    code=$?
    exit "$code"
else
    if [ "$SERVICES_ACTIVE" = "1" ]; then
        export DAGSTER_TEST_POSTGRES_URL="postgresql://${PG_USER}:${PG_USER}@${PG_HOST}:${PG_PORT}/test_dagster"
    fi
    export PYTHONNODEBUGRANGES="${PYTHONNODEBUGRANGES:-1}"
    export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"
    export MALLOC_ARENA_MAX="${MALLOC_ARENA_MAX:-2}"
    export MALLOC_TRIM_THRESHOLD_="${MALLOC_TRIM_THRESHOLD_:-131072}"
    export MALLOC_MMAP_THRESHOLD_="${MALLOC_MMAP_THRESHOLD_:-131072}"
    export PYTHON_GC_THRESHOLD_0="${PYTHON_GC_THRESHOLD_0:-10000}"
    export PYTHON_GC_THRESHOLD_1="${PYTHON_GC_THRESHOLD_1:-10}"
    export PYTHON_GC_THRESHOLD_2="${PYTHON_GC_THRESHOLD_2:-10}"
    export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
    export AWS_REGION="${AWS_REGION:-us-east-1}"

    TARGETS=()
    if [ "$#" -eq 1 ] && [[ "$1" == @* || ( -f "$1" && "$1" == *.txt ) ]]; then
        RAW_ARG="$1"
        FILE_PATH="${RAW_ARG#@}"
        if [ -f "$FILE_PATH" ]; then
            if ! rg -v -q '^[[:space:]]*$' "$FILE_PATH" 2>/dev/null; then
                echo "ℹ️  No test targets found in $FILE_PATH. Skipping pytest."
                exit 0
            fi
            mapfile -t TARGETS < <(rg -v '^[[:space:]]*$' "$FILE_PATH")
        else
            TARGETS=("$RAW_ARG")
        fi
    elif [ "$#" -gt 0 ]; then
        TARGETS=("$@")
    elif [ -n "${ENACT_TARGETS_FILE:-}" ] && [ -f "${ENACT_TARGETS_FILE}" ]; then
        if ! rg -v -q '^[[:space:]]*$' "${ENACT_TARGETS_FILE}" 2>/dev/null; then
            echo "ℹ️  No test targets found in ${ENACT_TARGETS_FILE}. Skipping pytest."
            exit 0
        fi
        mapfile -t TARGETS < <(rg -v '^[[:space:]]*$' "${ENACT_TARGETS_FILE}")
    fi

    REUSE_DB_ARG=""
    if [ "$SERVICES_ACTIVE" = "1" ]; then
        REUSE_DB_ARG="--reuse-db"
    fi
    exec python3 showcase/scripts/backend_runtime.py exec uv run --no-sync python -m pytest -p showcase.scripts.pytest_timings -o pythonhashseed=0 --import-mode=importlib -v $REUSE_DB_ARG "${TARGETS[@]}"
fi
