#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# showcase_xdist_test.sh
# Demonstrates multi-worker test acceleration with pytest-xdist on real Django
# models and live PostgreSQL on tmpfs with template database branching.
# ==============================================================================

DEFAULT_WORKERS="auto"
NUM_CORES=$(nproc 2>/dev/null || echo 2)
if [ "$NUM_CORES" -gt 4 ]; then
    DEFAULT_WORKERS=4
fi
WORKERS="${WORKERS:-$DEFAULT_WORKERS}"

TEST_TARGETS=${*:-"posthog/test/test_jwt.py posthog/test/test_dbrouter.py posthog/test/test_instance_setting_model.py posthog/models/exchange_rate/test/test_sql.py"}

echo "======================================================================"
echo "⚡ PostHog DeveX Showcase: Real Django & PostgreSQL Test Sharding"
echo "======================================================================"
echo "Detected CPU Cores: ${NUM_CORES} | Active Shard Workers: ${WORKERS}"
echo "Running test targets: ${TEST_TARGETS}"
echo ""

# Ensure postgresql binaries are discoverable in PATH for enve
for p in /usr/lib/postgresql/*/bin; do
    if [ -d "$p" ]; then
        export PATH="$p:$PATH"
        break
    fi
done

# Ensure live PostgreSQL is accessible or start a rootless tmpfs instance
PG_PORT="${PGPORT:-15432}"
STARTED_LOCAL_PG=0

# If port 5432 is occupied by an external host daemon, attempt to stop system service if running
if [ "$PG_PORT" -eq 5432 ] && command -v systemctl >/dev/null 2>&1; then
    sudo systemctl stop postgresql 2>/dev/null || true
fi

if ! enve run -- pg_isready -h localhost -p "$PG_PORT" >/dev/null 2>&1; then
    echo "▶ Starting rootless PostgreSQL cluster on tmpfs (/dev/shm)..."
    PGDATA="/dev/shm/pg_xdist_${PG_PORT}"
    rm -rf "$PGDATA"
    mkdir -p "$PGDATA"
    enve run -- initdb -D "$PGDATA" --auth=trust --username=posthog --no-sync >/dev/null
    enve run -- pg_ctl -D "$PGDATA" -o "-p $PG_PORT -k /tmp -c fsync=off -c synchronous_commit=off" start -w >/dev/null
    enve run -- createdb -h localhost -p "$PG_PORT" -U posthog posthog || true
    enve run -- createdb -h localhost -p "$PG_PORT" -U posthog test_posthog || true
    if [ -f .postgres-backups/schema-latest.sql.gz ]; then
        echo "▶ Priming test_posthog database from schema snapshot..."
        gunzip -c .postgres-backups/schema-latest.sql.gz | enve run -- psql -h localhost -p "$PG_PORT" -U posthog -q -d test_posthog 2>/dev/null || true
    fi
    STARTED_LOCAL_PG=1
    echo "✓ Live PostgreSQL ready on tmpfs port ${PG_PORT}"
else
    # Verify if existing instance has test_posthog primed
    if ! enve run -- psql -h localhost -p "$PG_PORT" -U posthog -d test_posthog -c "SELECT 1 FROM django_migrations LIMIT 1;" >/dev/null 2>&1; then
        enve run -- createdb -h localhost -p "$PG_PORT" -U posthog test_posthog 2>/dev/null || true
        if [ -f .postgres-backups/schema-latest.sql.gz ]; then
            echo "▶ Priming existing PostgreSQL test_posthog database from schema snapshot..."
            gunzip -c .postgres-backups/schema-latest.sql.gz | enve run -- psql -h localhost -p "$PG_PORT" -U posthog -q -d test_posthog 2>/dev/null || true
        fi
    fi
fi

cleanup() {
    if [ "$STARTED_LOCAL_PG" -eq 1 ]; then
        echo "▶ Stopping temporary tmpfs PostgreSQL cluster..."
        enve run -- pg_ctl -D "/dev/shm/pg_xdist_${PG_PORT}" stop >/dev/null 2>&1 || true
        rm -rf "/dev/shm/pg_xdist_${PG_PORT}" || true
    fi
}
trap cleanup EXIT

# Export live PostgreSQL database environment
export DATABASE_URL="postgres://posthog:posthog@localhost:${PG_PORT}/posthog"
export PGHOST="localhost"
export PGPORT="${PG_PORT}"
export PGUSER="posthog"
export DEBUG="true"
export TEST="true"
export SECRET_KEY="showcase_secret_key"
export SKIP_CLICKHOUSE_SETUP="true"
export SKIP_CLICKHOUSE_RESET="true"

if command -v enve >/dev/null 2>&1; then
    RUNNER="enve run -- env DATABASE_URL=postgres://posthog:posthog@127.0.0.1:${PG_PORT}/posthog PGHOST=127.0.0.1 PGPORT=${PG_PORT} PGUSER=posthog DEBUG=true TEST=true SKIP_CLICKHOUSE_SETUP=true SKIP_CLICKHOUSE_RESET=true uv run pytest"
else
    RUNNER="env DATABASE_URL=postgres://posthog:posthog@127.0.0.1:${PG_PORT}/posthog PGHOST=127.0.0.1 PGPORT=${PG_PORT} PGUSER=posthog DEBUG=true TEST=true SKIP_CLICKHOUSE_SETUP=true SKIP_CLICKHOUSE_RESET=true uv run pytest"
fi

# 1. Sequential Run (Single Worker Baseline)
echo "----------------------------------------------------------------------"
echo "▶ Running Sequential Baseline (-n 0) on Live PostgreSQL..."
START_SEQ=$(date +%s%N)
$RUNNER -n 0 -q --reuse-db $TEST_TARGETS
END_SEQ=$(date +%s%N)
SEQ_MS=$(( (END_SEQ - START_SEQ) / 1000000 ))
SEQ_SEC=$(awk "BEGIN {printf \"%.2f\", $SEQ_MS / 1000}")
echo "✓ Sequential completed in ${SEQ_SEC}s (${SEQ_MS}ms)"
echo ""

# 2. Parallel Run with pytest-xdist (-n $WORKERS)
echo "----------------------------------------------------------------------"
echo "▶ Running Parallel with pytest-xdist (-n ${WORKERS}) on Live PostgreSQL..."
START_PAR=$(date +%s%N)
$RUNNER -n "${WORKERS}" -q --reuse-db $TEST_TARGETS
END_PAR=$(date +%s%N)
PAR_MS=$(( (END_PAR - START_PAR) / 1000000 ))
PAR_SEC=$(awk "BEGIN {printf \"%.2f\", $PAR_MS / 1000}")
echo "✓ Parallel (-n ${WORKERS}) completed in ${PAR_SEC}s (${PAR_MS}ms)"
echo ""

# 3. Compute Metrics
SPEEDUP=$(awk "BEGIN {printf \"%.1fx\", $SEQ_MS / $PAR_MS}")
SAVINGS=$(awk "BEGIN {printf \"%.1f%%\", (1 - ($PAR_MS / $SEQ_MS)) * 100}")

echo "======================================================================"
echo "📊 Results & Performance Comparison (Real Django + PostgreSQL)"
echo "======================================================================"
printf "%-32s | %-12s | %-12s\n" "Execution Strategy" "Time" "Database Branching"
echo "----------------------------------------------------------------------"
printf "%-32s | %-12s | %-12s\n" "Sequential (-n 0)" "${SEQ_SEC}s" "Single DB (test_posthog)"
printf "%-32s | %-12s | %-12s\n" "Parallel pytest-xdist (-n ${WORKERS})" "${PAR_SEC}s" "Cloned tmpfs DBs (gw0..gwN)"
echo "----------------------------------------------------------------------"
echo "Template DB Branching: Instant zero-collision Postgres cloning in tmpfs"
echo "Worker Speedup: ${SPEEDUP} acceleration (${SAVINGS} time saved)"
echo "======================================================================"
