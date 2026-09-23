#!/usr/bin/env bash
# Per-worker test databases on the shared enve Postgres and ClickHouse.
#
# Every pytest worker (a test shard or the repo-invariants audit) gets its
# own clone of the migrated templates, so workers never share a database and
# never touch the templates while they run:
#   test_posthog          -> test_posthog_<worker>          (Django)
#   test_posthog_persons  -> test_posthog_<worker>_persons  (sqlx persons)
#   test_dagster_<worker>                                    (fresh)
#   ClickHouse posthog_test_<worker>                         (fresh)
# pytest-django appends "_<worker>" from TOX_PARALLEL_ENV, and PostHog's
# settings derive the persons and ClickHouse names from PYTEST_XDIST_WORKER,
# so the clones match what the worker connects to.
#
# The templates are built once, by the first worker to arrive, under a file
# lock; later workers wait for the lock and then for the templates to be free.
# Source this file and call prepare_worker_databases <worker>.

TEST_DB_LOCK="${ENACT_TEST_DB_LOCK:-.enact/test-databases.lock}"
TEMPLATE_DB="test_posthog"
TEMPLATE_PERSONS_DB="test_posthog_persons"
# A cheap database-backed test whose session setup creates and migrates the
# templates (Django, persons via sqlx, ClickHouse schema).
TEMPLATE_BOOTSTRAP_TEST="${ENACT_TEMPLATE_BOOTSTRAP_TEST:-posthog/hogql/test/test_mapping.py::TestMappings::test_unknown_type_mapping}"

pg() { psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -v ON_ERROR_STOP=1 -qtA "$@"; }

database_exists() { [ "$(pg -d postgres -c "SELECT 1 FROM pg_database WHERE datname = '$1'")" = "1" ]; }

template_ready() {
    database_exists "$TEMPLATE_DB" && database_exists "$TEMPLATE_PERSONS_DB" \
        && [ "$(pg -d "$TEMPLATE_DB" -c "SELECT 1 FROM pg_tables WHERE tablename = 'posthog_organization'")" = "1" ] \
        && [ "$(pg -d "$TEMPLATE_PERSONS_DB" -c "SELECT 1 FROM pg_tables WHERE tablename = 'posthog_person'")" = "1" ]
}

SNAPSHOT_DIR="${ENACT_TEMPLATE_SNAPSHOT_DIR:-${HOME}/.cache/enact/snapshots}"
PG_VERSION="${ENACT_PG_SNAPSHOT_VERSION:-15}"
POSTGRES_SNAPSHOT="${SNAPSHOT_DIR}/posthog_template_pg${PG_VERSION}.dump"
PERSONS_SNAPSHOT="${SNAPSHOT_DIR}/posthog_persons_template_pg${PG_VERSION}.dump"

restore_from_snapshots() {
    if [ -s "$POSTGRES_SNAPSHOT" ] && [ -s "$PERSONS_SNAPSHOT" ]; then
        echo "⚡ Restoring test database templates from snapshot ($POSTGRES_SNAPSHOT)" >&2
        database_exists "$TEMPLATE_DB" || pg -d postgres -c "CREATE DATABASE $TEMPLATE_DB;" >/dev/null
        database_exists "$TEMPLATE_PERSONS_DB" || pg -d postgres -c "CREATE DATABASE $TEMPLATE_PERSONS_DB;" >/dev/null
        pg_restore -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$TEMPLATE_DB" --no-owner --no-acl --clean --if-exists "$POSTGRES_SNAPSHOT" >/dev/null 2>&1 || true
        pg_restore -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$TEMPLATE_PERSONS_DB" --no-owner --no-acl --clean --if-exists "$PERSONS_SNAPSHOT" >/dev/null 2>&1 || true
        if template_ready; then
            echo "✓ Restored test database templates in <3s from snapshot" >&2
            return 0
        fi
        echo "⚠️ Snapshot restore incomplete; falling back to bootstrap" >&2
    fi
    return 1
}

dump_snapshots() {
    if template_ready; then
        mkdir -p "$SNAPSHOT_DIR"
        echo "💾 Caching test database templates to snapshot: $SNAPSHOT_DIR" >&2
        if pg_dump -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -Fc -d "$TEMPLATE_DB" -f "${POSTGRES_SNAPSHOT}.tmp" 2>/dev/null && [ -s "${POSTGRES_SNAPSHOT}.tmp" ]; then
            mv "${POSTGRES_SNAPSHOT}.tmp" "$POSTGRES_SNAPSHOT" 2>/dev/null || true
        fi
        if pg_dump -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -Fc -d "$TEMPLATE_PERSONS_DB" -f "${PERSONS_SNAPSHOT}.tmp" 2>/dev/null && [ -s "${PERSONS_SNAPSHOT}.tmp" ]; then
            mv "${PERSONS_SNAPSHOT}.tmp" "$PERSONS_SNAPSHOT" 2>/dev/null || true
        fi
    fi
}

# Rebuild the templates from scratch with pytest-django (--create-db) and no
# worker suffix, so they land under the template names.
bootstrap_templates() {
    restore_from_snapshots && return 0
    echo "Building test database templates ($TEMPLATE_DB, $TEMPLATE_PERSONS_DB)" >&2
    env -u PYTEST_XDIST_WORKER -u TOX_PARALLEL_ENV -u CLICKHOUSE_DATABASE \
        python3 showcase/scripts/backend_runtime.py exec uv run --no-sync python -m pytest \
        --create-db -p no:cacheprovider -o pythonhashseed=0 --import-mode=importlib -q \
        "$TEMPLATE_BOOTSTRAP_TEST" >&2
    if [ "$(pg -d "$TEMPLATE_PERSONS_DB" -c "SELECT 1 FROM pg_tables WHERE tablename = 'posthog_person'")" != "1" ]; then
        echo "Applying persons migrations to $TEMPLATE_PERSONS_DB..." >&2
        PERSONS_DB_WRITER_URL="postgres://${PGUSER}:${PGPASSWORD:-posthog}@${PGHOST}:${PGPORT}/${TEMPLATE_PERSONS_DB}" \
        python3 showcase/scripts/backend_runtime.py exec uv run --no-sync python manage.py apply_persons_migrations >&2 || true
    fi
    template_ready || { echo "Test database templates are missing after bootstrap" >&2; return 1; }
    dump_snapshots
}

# Wait until nothing is connected to the templates; CREATE DATABASE ... TEMPLATE
# refuses a template that has sessions.
wait_templates_free() {
    local deadline=$((SECONDS + ${ENACT_TEMPLATE_FREE_TIMEOUT:-120}))
    while :; do
        local sessions
        sessions=$(pg -d postgres -c "SELECT count(*) FROM pg_stat_activity WHERE datname IN ('$TEMPLATE_DB', '$TEMPLATE_PERSONS_DB')")
        [ "${sessions:-0}" = "0" ] && return 0
        if [ "$SECONDS" -ge "$deadline" ]; then
            echo "Test database templates still have $sessions sessions after ${ENACT_TEMPLATE_FREE_TIMEOUT:-120}s" >&2
            return 1
        fi
        sleep 1
    done
}

clone_database() { # <name> <template>
    database_exists "$1" || pg -d postgres -c "CREATE DATABASE $1 TEMPLATE $2;" >/dev/null
}

# Exports the worker's environment and creates its databases. Fails loudly.
prepare_worker_databases() { # <worker>
    local worker="$1"
    local posthog_db="test_posthog_${worker}"
    local persons_db="${posthog_db}_persons"
    local dagster_db="test_dagster_${worker}"
    local ch_db="posthog_test_${worker}"

    mkdir -p "$(dirname "$TEST_DB_LOCK")"
    (
        flock 9
        template_ready || bootstrap_templates
    ) 9>"$TEST_DB_LOCK"
    wait_templates_free
    # Every run starts from fresh clones and an empty ClickHouse database,
    # as upstream jobs start from fresh containers.
    for db in "$posthog_db" "$persons_db" "$dagster_db"; do
        database_exists "$db" && pg -d postgres -c "DROP DATABASE $db WITH (FORCE);" >/dev/null
    done
    clickhouse-client -q "DROP DATABASE IF EXISTS $ch_db SYNC;" >/dev/null
    clone_database "$posthog_db" "$TEMPLATE_DB"
    clone_database "$persons_db" "$TEMPLATE_PERSONS_DB"
    pg -d postgres -c "CREATE DATABASE $dagster_db;" >/dev/null
    clickhouse-client -q "CREATE DATABASE IF NOT EXISTS $ch_db;" >/dev/null

    local worker_num
    worker_num=$(echo "$worker" | tr -dc '0-9')
    if [ -n "$worker_num" ]; then
        export REDIS_URL="redis://${REDIS_HOST:-127.0.0.1}:${REDIS_PORT:-16379}/${worker_num}"
    fi

    if [ -f "showcase/scripts/create_test_kafka_topics.py" ] && [ -x ".venv/bin/python" ]; then
        .venv/bin/python showcase/scripts/create_test_kafka_topics.py "$worker" >/dev/null 2>&1 || true
    fi

    export TOX_PARALLEL_ENV="$worker"
    export PYTEST_XDIST_WORKER="$worker"
    export DAGSTER_TEST_POSTGRES_URL="postgresql://${PGUSER}:${PGUSER}@${PGHOST}:${PGPORT}/${dagster_db}"
    export PERSONS_DB_WRITER_URL="postgres://${PGUSER}:${PGUSER}@${PGHOST}:${PGPORT}/${persons_db}"
    export PERSONS_DATABASE_URL="postgres://${PGUSER}:${PGUSER}@${PGHOST}:${PGPORT}/${persons_db}"
    export CLICKHOUSE_DATABASE="$ch_db"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        snapshot)
            dump_snapshots
            ;;
        restore)
            restore_from_snapshots
            ;;
        *)
            echo "Usage: $0 [snapshot|restore]" >&2
            exit 1
            ;;
    esac
fi

