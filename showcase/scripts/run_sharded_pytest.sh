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

# Ensure libstdc++.so.6 is discoverable for C-extensions (grpc, etc.) without shadowing glibc
for candidate in \
    /nix/store/*-gcc-*-lib/lib \
    "$HOME/.local/share/enve/store"/*-gcc-*-lib/lib; do
    if [ -d "$candidate" ] && [ -f "$candidate/libstdc++.so.6" ]; then
        export LD_LIBRARY_PATH="${candidate}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        break
    fi
done

if [[ "${LD_LIBRARY_PATH:-}" != *"gcc"* ]]; then
    mkdir -p /tmp/enve-extra-libs
    for host_lib in /usr/lib/x86_64-linux-gnu/libstdc++.so.6 /lib/x86_64-linux-gnu/libstdc++.so.6; do
        if [ -f "$host_lib" ]; then
            ln -sf "$host_lib" /tmp/enve-extra-libs/libstdc++.so.6 2>/dev/null || true
            export LD_LIBRARY_PATH="/tmp/enve-extra-libs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
            break
        fi
    done
fi

SHARD="${ENACT_SHARD_INDEX:-${SHARD:-1}}"
TOTAL="${ENACT_SHARD_TOTAL:-${TOTAL_SHARDS:-1}}"

PG_HOST="${PGHOST:-127.0.0.1}"
PG_PORT="${PGPORT:-15432}"
PG_USER="${PGUSER:-posthog}"

if [ "$#" -eq 1 ] && [ -z "$1" ]; then
    shift
fi

if [ "$#" -eq 0 ] && [ -z "${ENACT_TARGETS_FILE:-}" ]; then
    echo "ℹ️  No test targets provided. Skipping pytest."
    exit 0
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

if [ "$TOTAL" -gt 1 ]; then
    WORKER_ID="shard${SHARD}"

    if [ "$SERVICES_ACTIVE" = "1" ]; then
        # shellcheck source=test_databases.sh
        source "$(dirname "${BASH_SOURCE[0]}")/test_databases.sh"
        prepare_worker_databases "$WORKER_ID"
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
    WORKER_ID="shard${SHARD:-1}"
    if [ "$SERVICES_ACTIVE" = "1" ]; then
        # shellcheck source=test_databases.sh
        source "$(dirname "${BASH_SOURCE[0]}")/test_databases.sh"
        prepare_worker_databases "$WORKER_ID"
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
