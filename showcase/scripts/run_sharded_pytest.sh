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
# record` and `reach sample` set it), each test file's footprint is recorded there as an
# enact reach map (pytest_footprint.py).
export PYTHONPATH="$ROOT/showcase/pytest_plugins${PYTHONPATH:+:$PYTHONPATH}"
export POSTHOG_REPO_ROOT="$ROOT"
export ENACT_REPLAY_RESULTS="${ENACT_REPLAY_RESULTS:-$ROOT/.enact/state/pytest}"
if [ -z "${TZDIR:-}" ] && [ ! -f /usr/share/zoneinfo/tzdata.zi ]; then
    _enve_store="${ENVE_STORE_DIR:-}"
    if [ -z "$_enve_store" ]; then
        _py_bin="$(command -v python3 2>/dev/null || true)"
        case "$_py_bin" in
            */*/*/*) _enve_store="${_py_bin%/*/*/*}" ;;
        esac
    fi
    for _tz_marker in tzdata.zi UTC; do
        for _tzdir in \
            ${_enve_store:+"$_enve_store"/*-tzdata-*/share/zoneinfo} \
            /nix/store/*-tzdata-*/share/zoneinfo \
            "$ROOT"/.venv/lib/python*/site-packages/tzdata/zoneinfo; do
            if [ -f "$_tzdir/$_tz_marker" ]; then
                export TZDIR="$_tzdir"
                break 2
            fi
        done
    done
fi
# pytest_snapshot_worker: snapshots compare this shard's ClickHouse database as upstream's.
# pytest_fail_early: a broken session-scoped fixture ends the pytest at once (exit 2).
# pytest_unmarked_db_setup: a test reaching django_db_setup without a django_db marker gets
# every test database set up, so a selection of such tests alone runs as in the whole suite.
PLUGINS=(-p pytest_timings -p pytest_snapshot_worker -p pytest_fail_early -p pytest_unmarked_db_setup -p pytest_query_tags)
if [ -n "${ENACT_FOOTPRINT_DIR:-}" ]; then
    PLUGINS+=(-p pytest_footprint)
fi

PG_HOST="${PGHOST:-127.0.0.1}"
PG_PORT="${PGPORT:-}"
PG_USER="${PGUSER:-posthog}"

if [ "$#" -eq 1 ] && { [ -z "$1" ] || [ "$1" = "@" ]; }; then
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

    # Under the declared enve postgres service (`ENVE_SERVICE_POSTGRES_PORT`), enve has
    # already waited for readiness and provisioned the `posthog` role and database.
    if [ -z "${ENVE_SERVICE_POSTGRES_PORT:-}" ]; then
        until pg_isready -h "$PG_HOST" -p "$PG_PORT" -q; do
            sleep 0.1
        done

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
if [ ! -f share/GeoLite2-City.mmdb ]; then
    if [ -n "${ENACT_HOST_CACHE:-}" ] && [ -s "$ENACT_HOST_CACHE/shared/GeoLite2-City.mmdb" ]; then
        mkdir -p share && cp "$ENACT_HOST_CACHE/shared/GeoLite2-City.mmdb" "share/GeoLite2-City.mmdb.tmp.$$" && mv -f "share/GeoLite2-City.mmdb.tmp.$$" share/GeoLite2-City.mmdb
    else
        showcase/scripts/exclusive.sh geoip ./bin/download-mmdb
        if [ -n "${ENACT_HOST_CACHE:-}" ] && [ -s share/GeoLite2-City.mmdb ]; then
            mkdir -p "$ENACT_HOST_CACHE/shared" && cp share/GeoLite2-City.mmdb "$ENACT_HOST_CACHE/shared/GeoLite2-City.mmdb.tmp.$$" && mv -f "$ENACT_HOST_CACHE/shared/GeoLite2-City.mmdb.tmp.$$" "$ENACT_HOST_CACHE/shared/GeoLite2-City.mmdb"
        fi
    fi
fi

if [ "$SERVICES_ACTIVE" = "1" ]; then
    # shellcheck source=test_databases.sh
    source "$(dirname "${BASH_SOURCE[0]}")/test_databases.sh"
    # The run's jobs share its services: base:test's and products:test's shard 1 run at
    # once, so the worker is named for the component and job too (ENACT_COMPONENT, ENACT_JOB).
    WORKER_ID="$(test_worker_name "${ENACT_COMPONENT:-}" "${ENACT_JOB:-}" "$SHARD")"
    prepare_worker_databases "$WORKER_ID"
    # Clean per-worker ClickHouse materialized-column baseline file: captured once after the
    # first DB migration and enforced between product subprocesses (surviving SIGKILL/OOM).
    export ENACT_CH_MAT_BASELINE_FILE="$ROOT/.enact/state/ch-mat-baseline-${WORKER_ID}.json"
    rm -f "$ENACT_CH_MAT_BASELINE_FILE"
    # Worker DB routing for warehouse_sources (settings/data_warehouse.py reads WAREHOUSE_SOURCES_DATABASE_URL
    # before PRODUCT_DB_WRITER_URLS, which points at the un-prefixed posthog_<worker>_warehouse_sources_queue).
    export WAREHOUSE_SOURCES_DATABASE_URL="postgres://${PGUSER}:${PGPASSWORD:-posthog}@${PGHOST}:${PGPORT}/test_posthog_${WORKER_ID}"
    # Generate ephemeral RSA keys once per shard for OIDC and tasks sandbox JWT signing tests.
    if { [ -z "${OIDC_RSA_PRIVATE_KEY:-}" ] || [ -z "${SANDBOX_JWT_PRIVATE_KEY:-}" ]; } && [ -x .venv/bin/python ]; then
        _shard_rsa_key="$(.venv/bin/python -c 'from cryptography.hazmat.primitives import serialization as s
from cryptography.hazmat.primitives.asymmetric import rsa
key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
print(key.private_bytes(s.Encoding.PEM, s.PrivateFormat.TraditionalOpenSSL, s.NoEncryption()).decode())' 2>/dev/null || true)"
        if [ -n "$_shard_rsa_key" ]; then
            export OIDC_RSA_PRIVATE_KEY="${OIDC_RSA_PRIVATE_KEY:-$_shard_rsa_key}"
            export SANDBOX_JWT_PRIVATE_KEY="${SANDBOX_JWT_PRIVATE_KEY:-$_shard_rsa_key}"
        fi
    fi
fi

# Memory & Python Runtime Optimizations
unset LD_PRELOAD
# pyarrow's manylinux wheel compiles arrow_vendored::date::get_tz_dir() with USE_OS_TZDB=1,
# which ignores TZDIR and stats only /usr/share/zoneinfo{/uclibc}. Minimal CI containers
# omit /usr/share/zoneinfo; build a libc-only (no -ldl) path-remap shim scoped strictly to
# the pytest invocations below so host-glibc helpers (`enact`) never load Nix glibc libs.
TZ_LD_PRELOAD=""
if [ ! -d /usr/share/zoneinfo ] && [ -n "${TZDIR:-}" ] && [ "$(uname -s)" = Linux ] && command -v cc >/dev/null 2>&1; then
    mkdir -p "$ROOT/.enact/state"
    _tz_so="$ROOT/.enact/state/tzdir-shim-v2-${HOSTTYPE:-linux}.so"
    if [ ! -s "$_tz_so" ]; then
        _tz_tmp="${_tz_so}.$$"
        cat <<'TZSHIM' | cc -shared -fPIC -O2 -fno-stack-protector -x c - -o "$_tz_tmp" 2>/dev/null && mv -f "$_tz_tmp" "$_tz_so" || rm -f "$_tz_tmp"
#define _GNU_SOURCE
#include <dlfcn.h>
#include <dirent.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static const char *enact_tz_remap(const char *p, char *b, size_t cap) {
    const char *pfx = "/usr/share/zoneinfo";
    if (!p || strncmp(p, pfx, 19) != 0 || (p[19] != '\0' && p[19] != '/')) return p;
    const char *tz = getenv("TZDIR");
    if (!tz || !*tz) return p;
    int n = snprintf(b, cap, "%s%s", tz, p + 19);
    return (n > 0 && (size_t)n < cap) ? b : p;
}
int __xstat(int v, const char *p, struct stat *s) {
    static int (*fn)(int, const char *, struct stat *);
    if (!fn) fn = dlsym(RTLD_NEXT, "__xstat");
    char b[4096]; return fn(v, enact_tz_remap(p, b, sizeof b), s);
}
int __xstat64(int v, const char *p, struct stat64 *s) {
    static int (*fn)(int, const char *, struct stat64 *);
    if (!fn) fn = dlsym(RTLD_NEXT, "__xstat64");
    char b[4096]; return fn(v, enact_tz_remap(p, b, sizeof b), s);
}
int stat(const char *p, struct stat *s) {
    static int (*fn)(const char *, struct stat *);
    if (!fn) fn = dlsym(RTLD_NEXT, "stat");
    char b[4096]; return fn(enact_tz_remap(p, b, sizeof b), s);
}
int stat64(const char *p, struct stat64 *s) {
    static int (*fn)(const char *, struct stat64 *);
    if (!fn) fn = dlsym(RTLD_NEXT, "stat64");
    char b[4096]; return fn(enact_tz_remap(p, b, sizeof b), s);
}
int newfstatat(int fd, const char *p, struct stat *s, int f) {
    static int (*fn)(int, const char *, struct stat *, int);
    if (!fn) fn = dlsym(RTLD_NEXT, "newfstatat");
    char b[4096]; return fn(fd, enact_tz_remap(p, b, sizeof b), s, f);
}
int fstatat(int fd, const char *p, struct stat *s, int f) {
    static int (*fn)(int, const char *, struct stat *, int);
    if (!fn) fn = dlsym(RTLD_NEXT, "fstatat");
    char b[4096]; return fn(fd, enact_tz_remap(p, b, sizeof b), s, f);
}
int fstatat64(int fd, const char *p, struct stat64 *s, int f) {
    static int (*fn)(int, const char *, struct stat64 *, int);
    if (!fn) fn = dlsym(RTLD_NEXT, "fstatat64");
    char b[4096]; return fn(fd, enact_tz_remap(p, b, sizeof b), s, f);
}
DIR *opendir(const char *p) {
    static DIR *(*fn)(const char *);
    if (!fn) fn = dlsym(RTLD_NEXT, "opendir");
    char b[4096]; return fn(enact_tz_remap(p, b, sizeof b));
}
FILE *fopen(const char *p, const char *m) {
    static FILE *(*fn)(const char *, const char *);
    if (!fn) fn = dlsym(RTLD_NEXT, "fopen");
    char b[4096]; return fn(enact_tz_remap(p, b, sizeof b), m);
}
FILE *fopen64(const char *p, const char *m) {
    static FILE *(*fn)(const char *, const char *);
    if (!fn) fn = dlsym(RTLD_NEXT, "fopen64");
    char b[4096]; return fn(enact_tz_remap(p, b, sizeof b), m);
}
int open(const char *p, int f, ...) {
    static int (*fn)(const char *, int, mode_t);
    if (!fn) fn = dlsym(RTLD_NEXT, "open");
    mode_t m = 0; if (f & O_CREAT) { va_list a; va_start(a, f); m = va_arg(a, int); va_end(a); }
    char b[4096]; return fn(enact_tz_remap(p, b, sizeof b), f, m);
}
int open64(const char *p, int f, ...) {
    static int (*fn)(const char *, int, mode_t);
    if (!fn) fn = dlsym(RTLD_NEXT, "open64");
    mode_t m = 0; if (f & O_CREAT) { va_list a; va_start(a, f); m = va_arg(a, int); va_end(a); }
    char b[4096]; return fn(enact_tz_remap(p, b, sizeof b), f, m);
}
int openat(int fd, const char *p, int f, ...) {
    static int (*fn)(int, const char *, int, mode_t);
    if (!fn) fn = dlsym(RTLD_NEXT, "openat");
    mode_t m = 0; if (f & O_CREAT) { va_list a; va_start(a, f); m = va_arg(a, int); va_end(a); }
    char b[4096]; return fn(fd, enact_tz_remap(p, b, sizeof b), f, m);
}
TZSHIM
    fi
    if [ -s "$_tz_so" ]; then
        TZ_LD_PRELOAD="$_tz_so"
    fi
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
export AWS_S3_ADDRESSING_STYLE="${AWS_S3_ADDRESSING_STYLE:-path}"

# Resolve test targets (supports @argfile, raw file path, positional args, or $ENACT_TARGETS_FILE)
TARGETS=()
if [ "$#" -eq 1 ] && [[ "$1" == @* ]]; then
    FILE_PATH="${1#@}"
    if [ -z "$FILE_PATH" ] || [ ! -f "$FILE_PATH" ] || ! rg -v -q '^[[:space:]]*$' "$FILE_PATH"; then
        echo "✗ run_sharded_pytest.sh: no test targets in ${FILE_PATH:-$1}" >&2
        exit 1
    fi
    mapfile -t TARGETS < <(rg -v '^[[:space:]]*$' "$FILE_PATH")
elif [ "$#" -eq 1 ] && [[ -f "$1" && "$1" == *.txt ]]; then
    if ! rg -v -q '^[[:space:]]*$' "$1"; then
        echo "✗ run_sharded_pytest.sh: no test targets in $1" >&2
        exit 1
    fi
    mapfile -t TARGETS < <(rg -v '^[[:space:]]*$' "$1")
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
run_backend_pytest() {
    if [ -n "$TZ_LD_PRELOAD" ]; then
        LD_PRELOAD="$TZ_LD_PRELOAD" python3 showcase/scripts/backend_runtime.py exec "$@"
    else
        python3 showcase/scripts/backend_runtime.py exec "$@"
    fi
}

if [ "${ENACT_COLLECT_ONLY:-0}" = 1 ]; then
    if [ -n "$TZ_LD_PRELOAD" ]; then
        export LD_PRELOAD="$TZ_LD_PRELOAD"
    fi
    exec python3 showcase/scripts/backend_runtime.py exec \
        uv run --no-sync python -m pytest "${PLUGINS[@]}" "${LEFT_OUT[@]}" -o pythonhashseed=0 \
        --collect-only -q "${TARGETS[@]}"
fi

# One pytest per product and per core segment (product_pytest.py), sequentially; the shard
# fails with the last failing run's code, as ci-backend.yml's legs. A run collecting nothing
# (pytest's 5) fails too: its targets were selected as tests, so none running is a stale
# target or a product's flags deselecting it, never a pass.
runs="$(printf '%s\n' "${TARGETS[@]}" | python3 showcase/scripts/product_pytest.py -)"
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
        ENACT_PYTEST_GROUP="$group" run_backend_pytest \
            uv run --no-sync python -m pytest "${PLUGINS[@]}" "${LEFT_OUT[@]}" -o pythonhashseed=0 "${REUSE_DB_ARG[@]}" "${args[@]}"
    else
        (
            [ -z "$PRODUCT_OBJECT_STORAGE_ENDPOINT" ] || export OBJECT_STORAGE_ENDPOINT="$PRODUCT_OBJECT_STORAGE_ENDPOINT"
            [ -z "$TZ_LD_PRELOAD" ] || export LD_PRELOAD="$TZ_LD_PRELOAD"
            if [ "$group" = "signals" ]; then
                # Avoid scout_report <-> scout_harness circular import when shards collect test_report_embeddings before test_billing,
                # preloading in pytest_collection so pytest-django initializes django.setup() first.
                PYTHONPATH="$ROOT${PYTHONPATH:+:$PYTHONPATH}" ENACT_PYTEST_GROUP="$group" exec python3 showcase/scripts/backend_runtime.py exec \
                    uv run --no-sync --directory "$dir" python -c 'import sys, pytest; P=type("P",(),{"pytest_collection":lambda self: (__import__("products.signals.backend.scout_harness.tools.emit"), None)[1]}); raise SystemExit(pytest.main(sys.argv[1:], plugins=[P()]))' "${PLUGINS[@]}" "${LEFT_OUT[@]}" -o pythonhashseed=0 "${REUSE_DB_ARG[@]}" "${args[@]}"
            else
                ENACT_PYTEST_GROUP="$group" exec python3 showcase/scripts/backend_runtime.py exec \
                    uv run --no-sync --directory "$dir" pytest "${PLUGINS[@]}" "${LEFT_OUT[@]}" -o pythonhashseed=0 "${REUSE_DB_ARG[@]}" "${args[@]}"
            fi
        )
    fi
    code=$?
    if [ "$SERVICES_ACTIVE" = "1" ] && [ "${#RUNS[@]}" -gt 1 ]; then
        if [ -n "${CLICKHOUSE_DATABASE:-}" ] && [ -s "${ENACT_CH_MAT_BASELINE_FILE:-}" ]; then
            python3 "$ROOT/showcase/pytest_plugins/pytest_snapshot_worker.py" cleanup-clickhouse \
                "$CLICKHOUSE_DATABASE" "$ENACT_CH_MAT_BASELINE_FILE" || true
        else
            echo "pytest_snapshot_worker: inter-product ClickHouse cleanup skipped in run_sharded_pytest.sh after [$group]: CLICKHOUSE_DATABASE=${CLICKHOUSE_DATABASE:-<unset>} baseline_exists=$([ -s "${ENACT_CH_MAT_BASELINE_FILE:-}" ] && echo yes || echo no) (${ENACT_CH_MAT_BASELINE_FILE:-<unset>})" >&2
        fi
    fi
    if [ "$code" -eq 5 ]; then
        echo "✗ pytest [$group] in $dir collected no tests from its targets" >&2
    fi
    # pytest broke (interrupted, internal or usage error: components.cue's _pytestErrors):
    # the shard's later runs would prove nothing, and enact stops the run on this exit.
    case "$code" in 2|3|4) exit "$code" ;; esac
    [ "$code" -eq 0 ] || overall=$code
done
exit "$overall"
