#!/usr/bin/env bash
# ==============================================================================
# Declarative Sharded Test Runner with Automatic Database Isolation
# Provisions isolated PostgreSQL & ClickHouse database slices per shard, named for the
# worker <component>_<job>_shard${SHARD} (test_databases.sh's test_worker_name):
#   • test_posthog_<worker>
#   • test_posthog_<worker>_persons
#   • test_dagster_<worker>
#   • posthog_test_<worker>
# Products run as upstream's product jobs run them (turbo's backend:test): one pytest
# process per product, from its directory with its own script's flags, one after another
# (product_pytest.py); core's targets are one process from the repository root.
# ==============================================================================
set -euo pipefail
unset LD_PRELOAD
# The env's seaweedfs exports AWS_ENDPOINT_URL, which CI's test env doesn't have: boto3 clients
# built without an endpoint (the transfer-acceleration presigner) took it, and botocore refuses a
# custom endpoint with S3 Accelerate. The tests reach object storage by OBJECT_STORAGE_ENDPOINT.
unset AWS_ENDPOINT_URL AWS_ENDPOINT_URL_S3
export PATH="$PWD/bin:$PATH"

# libstdc++ for the native wheels comes from the env (enve.cue: gcc-unwrapped).

SHARD="${ENACT_SHARD_INDEX:-${SHARD:-1}}"
ROOT="$PWD"
# The plugins load from a directory of their own, so they import from a product's directory
# too. pytest's entry-point plugin lookup (importlib.metadata) lists every directory on the
# path, so each footprint holds that listing: beside the helpers, each new script would
# stale every Python footprint. With ENACT_FOOTPRINT_DIR (a directory: `enact trace
# record` and `trace sample` set it), each test file's footprint is recorded there as an
# enact reach map (pytest_footprint.py).
export PYTHONPATH="$ROOT/showcase/pytest_plugins${PYTHONPATH:+:$PYTHONPATH}"
export POSTHOG_REPO_ROOT="$ROOT"
export ENACT_REPLAY_RESULTS="${ENACT_REPLAY_RESULTS:-$ROOT/.enact/state/pytest}"
# pytest_snapshot_worker: snapshots compare this shard's ClickHouse database as upstream's.
# pytest_fail_early: a broken session-scoped fixture ends the pytest at once (exit 2).
# pytest_unmarked_db_setup: a test reaching django_db_setup without a django_db marker gets
# every test database set up, so a selection of such tests alone runs as in the whole suite.
PLUGINS=(-p pytest_timings -p pytest_snapshot_worker -p pytest_fail_early -p pytest_unmarked_db_setup)
if [ -n "${ENACT_FOOTPRINT_DIR:-}" ]; then
    PLUGINS+=(-p pytest_footprint)
fi

PG_HOST="${PGHOST:-127.0.0.1}"
PG_PORT="${PGPORT:-}"
PG_USER="${PGUSER:-posthog}"

if [ "$#" -eq 1 ] && [ -z "$1" ]; then
    shift
fi

# It runs the targets it is given, never nothing: enact gives every shard it starts its
# targets (it plans no more shards than the targets fill, and fails a shard left without
# any), so none is a mistake, not a pass.
if [ "$#" -eq 0 ] && [ -z "${ENACT_TARGETS_FILE:-}" ]; then
    echo "✗ run_sharded_pytest.sh: no test targets (arguments, @file or ENACT_TARGETS_FILE)" >&2
    exit 1
fi

SERVICES_ACTIVE="${ENACT_SERVICES_ACTIVE:-1}"
# ENACT_COLLECT_ONLY=1 (enve-ready.conf's COLLECT): list the targets' tests, no services.
if [ -z "${PGPORT:-}" ] || [ "${SERVICES_ACTIVE}" = "0" ] || [ "${ENACT_COLLECT_ONLY:-0}" = 1 ]; then
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
    until pg_isready -h "$PG_HOST" -p "$PG_PORT" -q; do
        sleep 0.1
    done

    # Ensure role posthog exists with superuser privileges in PostgreSQL
    for admin_user in postgres "${USER:-}" runner "$(whoami 2>/dev/null || echo '')"; do
        [ -n "$admin_user" ] || continue
        if psql -h "$PG_HOST" -p "$PG_PORT" -U "$admin_user" -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
            psql -h "$PG_HOST" -p "$PG_PORT" -U "$admin_user" -d postgres -c \
                "DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$PG_USER') THEN CREATE ROLE $PG_USER WITH SUPERUSER LOGIN CREATEDB PASSWORD 'posthog'; ELSE ALTER ROLE $PG_USER WITH SUPERUSER CREATEDB; END IF; END \$\$;" >/dev/null 2>&1 || true
            psql -h "$PG_HOST" -p "$PG_PORT" -U "$admin_user" -d postgres -c "CREATE DATABASE $PG_USER OWNER $PG_USER;" >/dev/null 2>&1 || true
            break
        fi
    done
fi

# The backend runtime (the uv venv and its stamp) is installed before any shard starts:
# ci.cue's toolchain.python.install (setup.sh backend), which CI's install step and a local
# `enact run`'s prepare phase each run once. The shards only read it.

# As ci-backend.yml's "Set up needed files": Django renders the frontend's templates
# (stubs where no frontend build is present) and GeoIP reads the city database.
mkdir -p frontend/dist
for page in index layout exporter; do
    [ -e "frontend/dist/$page.html" ] || touch "frontend/dist/$page.html"
done
showcase/scripts/exclusive.sh geoip ./bin/download-mmdb

if [ "$SERVICES_ACTIVE" = "1" ]; then
    # shellcheck source=test_databases.sh
    source "$(dirname "${BASH_SOURCE[0]}")/test_databases.sh"
    # The run's jobs share its services: base:test's and products:test's shard 1 run at
    # once, so the worker is named for the component and job too (ENACT_COMPONENT, ENACT_JOB).
    WORKER_ID="$(test_worker_name "${ENACT_COMPONENT:-}" "${ENACT_JOB:-}" "$SHARD")"
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
        if ! rg -v -q '^[[:space:]]*$' "$FILE_PATH"; then
            echo "✗ run_sharded_pytest.sh: no test targets in $FILE_PATH" >&2
            exit 1
        fi
        mapfile -t TARGETS < <(rg -v '^[[:space:]]*$' "$FILE_PATH")
    else
        TARGETS=("$RAW_ARG")
    fi
elif [ "$#" -gt 0 ]; then
    TARGETS=("$@")
elif [ -n "${ENACT_TARGETS_FILE:-}" ] && [ -f "${ENACT_TARGETS_FILE}" ]; then
    if ! rg -v -q '^[[:space:]]*$' "${ENACT_TARGETS_FILE}"; then
        echo "✗ run_sharded_pytest.sh: no test targets in ${ENACT_TARGETS_FILE}" >&2
        exit 1
    fi
    mapfile -t TARGETS < <(rg -v '^[[:space:]]*$' "${ENACT_TARGETS_FILE}")
fi

if [ "${#TARGETS[@]}" -eq 0 ]; then
    echo "✗ run_sharded_pytest.sh: shard ${SHARD} has no test targets" >&2
    exit 1
fi

# Tagged out on macOS until chdb-core's lock moves (agentic/ISSUES.md U31): these import chdb,
# whose `_chdb.abi3.so` (chdb-core 26.7.0) macOS 27's dyld refuses ("mis-aligned LINKEDIT
# string pool"; chdb-core PR #249, unreleased). Linux runs them. A target naming one is
# dropped; a directory target holding one skips it (--ignore, absolute: products run from
# their own directory).
LEFT_OUT=()
if [ "$(uname -s)" = Darwin ]; then
    for path in products/web_analytics/backend/hogql_queries/external/test/test_summary_query_runner.py \
        products/web_analytics/dags/tests/test_web_preaggregated_asset_checks.py; do
        kept=()
        held=0
        for target in "${TARGETS[@]}"; do
            if [ "${target%%::*}" = "$path" ]; then
                echo "⊘ $target: left out on macOS (chdb won't load there, U31)" >&2
                continue
            fi
            kept+=("$target")
            case "$target" in
            -*) ;;
            .) held=1 ;;
            *) [[ "$path" != "${target%/}/"* ]] || held=1 ;;
            esac
        done
        TARGETS=(${kept[@]+"${kept[@]}"})
        [ "$held" = 0 ] || LEFT_OUT+=("--ignore=$ROOT/$path")
    done
    if [ "${#TARGETS[@]}" -eq 0 ]; then
        echo "⊘ run_sharded_pytest.sh: shard ${SHARD}'s every target is left out on macOS" >&2
        exit 0
    fi
fi

REUSE_DB_ARG=()
if [ "$SERVICES_ACTIVE" = "1" ]; then
    REUSE_DB_ARG=(--reuse-db)
fi

# Upstream runs the products under turbo, whose strict env mode passes a task only turbo.json's
# backend:test env: ci-backend.yml's OBJECT_STORAGE_ENDPOINT (localhost:19000) never reaches
# them, so they take settings' TEST default, objectstorage:19000 (CI's /etc/hosts maps it to
# 127.0.0.1). The name matters: under DEBUG, exports' get_content_response redirects to a
# presigned URL only off localhost, else it reads the object itself (replay_vision's thumbnail
# tests write none and expect the redirect). `localhost.` is a loopback name that isn't
# `localhost` and resolves without /etc/hosts, on macOS and glibc alike.
PRODUCT_OBJECT_STORAGE_ENDPOINT=""
if [[ "${OBJECT_STORAGE_ENDPOINT:-}" == http://localhost:* ]]; then
    PRODUCT_OBJECT_STORAGE_ENDPOINT="http://localhost.:${OBJECT_STORAGE_ENDPOINT#http://localhost:}"
fi

# A collection imports every test module the runs below would, in one pytest from the root:
# a product's flags (-m, -k, reruns) select among its tests, they import nothing more. Each
# product runs in a process of its own below, so their same-named test packages (`tests`)
# never meet; a collection of several passes --import-mode=importlib among its arguments.
if [ "${ENACT_COLLECT_ONLY:-0}" = 1 ]; then
    exec python3 showcase/scripts/backend_runtime.py exec \
        uv run --no-sync python -m pytest "${PLUGINS[@]}" "${LEFT_OUT[@]}" -o pythonhashseed=0 \
        --collect-only -q "${TARGETS[@]}"
fi

# One pytest per product and per core segment (product_pytest.py), sequentially; the shard
# fails with the last failing run's code, as ci-backend.yml's legs. A run collecting nothing
# (pytest's 5) fails too: its targets were selected as tests, so none running is a stale
# target or a product's flags deselecting it, never a pass.
runs="$(python3 showcase/scripts/product_pytest.py "${TARGETS[@]}")"
mapfile -t RUNS <<<"$runs"
if [ -z "$runs" ] || [ "${#RUNS[@]}" -eq 0 ]; then
    echo "✗ run_sharded_pytest.sh: product_pytest.py planned no pytest run for ${#TARGETS[@]} target(s)" >&2
    exit 1
fi
set +e
overall=0
for run in "${RUNS[@]}"; do
    group="${run%%$'\t'*}"
    run="${run#*$'\t'}"
    dir="${run%%$'\t'*}"
    eval "args=(${run#*$'\t'})"
    [ "${#RUNS[@]}" -eq 1 ] || echo "▶ pytest [$group] in $dir: ${#args[@]} arguments"
    if [ "$dir" = "." ]; then
        ENACT_PYTEST_GROUP="$group" python3 showcase/scripts/backend_runtime.py exec \
            uv run --no-sync python -m pytest "${PLUGINS[@]}" "${LEFT_OUT[@]}" -o pythonhashseed=0 "${REUSE_DB_ARG[@]}" "${args[@]}"
    else
        (
            [ -z "$PRODUCT_OBJECT_STORAGE_ENDPOINT" ] || export OBJECT_STORAGE_ENDPOINT="$PRODUCT_OBJECT_STORAGE_ENDPOINT"
            ENACT_PYTEST_GROUP="$group" exec python3 showcase/scripts/backend_runtime.py exec \
                uv run --no-sync --directory "$dir" pytest "${PLUGINS[@]}" "${LEFT_OUT[@]}" -o pythonhashseed=0 "${REUSE_DB_ARG[@]}" "${args[@]}"
        )
    fi
    code=$?
    if [ "$code" -eq 5 ]; then
        echo "✗ pytest [$group] in $dir collected no tests from its targets" >&2
    fi
    # pytest broke (interrupted, internal or usage error: components.cue's _pytestErrors):
    # the shard's later runs would prove nothing, and enact stops the run on this exit.
    case "$code" in 2|3|4) exit "$code" ;; esac
    [ "$code" -eq 0 ] || overall=$code
done
exit "$overall"
